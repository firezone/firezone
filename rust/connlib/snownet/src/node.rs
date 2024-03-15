use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::PublicKey;
use boringtun::{noise::rate_limiter::RateLimiter, x25519::StaticSecret};
use core::{fmt, slice};
use pnet_packet::ipv4::MutableIpv4Packet;
use pnet_packet::ipv6::MutableIpv6Packet;
use pnet_packet::Packet;
use rand::random;
use secrecy::{ExposeSecret, Secret};
use std::hash::Hash;
use std::marker::PhantomData;
use std::time::{Duration, Instant};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    net::SocketAddr,
    sync::Arc,
};
use str0m::ice::{IceAgent, IceAgentEvent, IceCreds, StunMessage, StunPacket};
use str0m::net::Protocol;
use str0m::{Candidate, CandidateKind, IceConnectionState};

use crate::allocation::{Allocation, Socket};
use crate::index::IndexLfsr;
use crate::stats::{ConnectionStats, NodeStats};
use crate::stun_binding::StunBinding;
use crate::utils::earliest;
use crate::{IpPacket, MutableIpPacket};
use boringtun::noise::errors::WireGuardError;
use std::borrow::Cow;
use std::iter;
use std::ops::ControlFlow;
use stun_codec::rfc5389::attributes::{Realm, Username};
use tracing::{field, info_span, Span};

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

/// How long we will at most wait for a candidate from the remote.
const CANDIDATE_TIMEOUT: Duration = Duration::from_secs(10);

/// How long we will at most wait for an [`Answer`] from the remote.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);

const MAX_UDP_SIZE: usize = (1 << 16) - 1;

/// Manages a set of wireguard connections for a server.
pub type ServerNode<TId> = Node<Server, TId>;
/// Manages a set of wireguard connections for a client.
pub type ClientNode<TId> = Node<Client, TId>;

pub enum Server {}
pub enum Client {}

/// A node within a `snownet` network maintains connections to several other nodes.
///
/// [`Node`] is built in a SANS-IO fashion, meaning it neither advances time nor network state on its own.
/// Instead, you need to call one of the following functions:
///
/// - [`Node::decapsulate`] for handling incoming network traffic
/// - [`Node::encapsulate`] for handling outgoing network traffic
/// - [`Node::handle_timeout`] for waking the [`Node`]
///
/// As a counterpart, the following functions inform you about state changes and "actions" the [`Node`] would like to take:
///
/// - [`Node::poll_timeout`] for learning when to "wake" the [`Node`]
/// - [`Node::poll_transmit`] for transferring buffered data
/// - [`Node::poll_event`] for learning about state changes
///
/// These sets of functions need to be combined into an event-loop by the caller.
/// Any time you change a [`Node`]'s state, you should call [`Node::poll_timeout`] to accurately update, when the [`Node`] wants to be woken up for any time-based actions.
/// In other words, it should be a loop of:
///
/// 1. Change [`Node`]'s state (either via network messages, adding a new connection, etc)
/// 2. Check [`Node::poll_timeout`] for when to wake the [`Node`]
/// 3. Call [`Node::handle_timeout`] once that time is reached
pub struct Node<T, TId> {
    private_key: StaticSecret,
    index: IndexLfsr,
    rate_limiter: Arc<RateLimiter>,
    host_candidates: HashSet<Candidate>,
    buffered_transmits: VecDeque<Transmit<'static>>,

    next_rate_limiter_reset: Option<Instant>,

    bindings: HashMap<SocketAddr, StunBinding>,
    allocations: HashMap<SocketAddr, Allocation>,

    connections: Connections<TId>,
    pending_events: VecDeque<Event<TId>>,

    buffer: Box<[u8; MAX_UDP_SIZE]>,

    stats: NodeStats,

    marker: PhantomData<T>,
}

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("Unknown interface")]
    UnknownInterface,
    #[error("Failed to decapsulate: {0:?}")] // TODO: Upstream an std::error::Error impl
    Decapsulate(boringtun::noise::errors::WireGuardError),
    #[error("Failed to encapsulate: {0:?}")]
    Encapsulate(boringtun::noise::errors::WireGuardError),
    #[error("Packet is a STUN message but no agent handled it; num_agents = {num_agents}")]
    UnhandledStunMessage { num_agents: usize },
    #[error("Packet was not accepted by any wireguard tunnel; num_tunnels = {num_tunnels}")]
    UnhandledPacket { num_tunnels: usize },
    #[error("Not connected")]
    NotConnected,
    #[error("Invalid local address: {0}")]
    BadLocalAddress(#[from] str0m::error::IceError),
}

impl<T, TId> Node<T, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    pub fn new(private_key: StaticSecret) -> Self {
        let public_key = &(&private_key).into();
        Self {
            private_key,
            marker: Default::default(),
            index: IndexLfsr::default(),
            rate_limiter: Arc::new(RateLimiter::new(public_key, HANDSHAKE_RATE_LIMIT)),
            host_candidates: HashSet::default(),
            buffered_transmits: VecDeque::default(),
            next_rate_limiter_reset: None,
            pending_events: VecDeque::default(),
            buffer: Box::new([0u8; MAX_UDP_SIZE]),
            bindings: HashMap::default(),
            allocations: HashMap::default(),
            connections: Default::default(),
            stats: Default::default(),
        }
    }

    pub fn reconnect(&mut self, now: Instant) {
        for binding in self.bindings.values_mut() {
            binding.refresh(now);
        }

        for allocation in self.allocations.values_mut() {
            allocation.refresh(now);
        }
    }

    pub fn public_key(&self) -> PublicKey {
        (&self.private_key).into()
    }

    pub fn is_connected_to(&self, key: PublicKey) -> bool {
        self.connections
            .iter_established()
            .any(|(_, c)| c.remote_pub_key == key && c.tunnel.time_since_last_handshake().is_some())
    }

    pub fn stats(&self) -> (NodeStats, impl Iterator<Item = (TId, ConnectionStats)> + '_) {
        (self.stats, self.connections.stats())
    }

    /// Add an address as a `host` candidate.
    ///
    /// For most network topologies, [`snownet`](crate) will automatically discover host candidates via the traffic to the configured STUN and TURN servers.
    /// However, in topologies like the one below, we cannot discover that there is a more optimal link between BACKEND and DB.
    /// For those situations, users need to manually add the address of the direct link in order for [`snownet`](crate) to establish a connection.
    ///
    /// ```text
    ///        ┌──────┐          ┌──────┐
    ///        │ STUN ├─┐      ┌─┤ TURN │
    ///        └──────┘ │      │ └──────┘
    ///                 │      │
    ///               ┌─┴──────┴─┐
    ///      ┌────────┤   WAN    ├───────┐
    ///      │        └──────────┘       │
    /// ┌────┴─────┐                  ┌──┴───┐
    /// │    FW    │                  │  FW  │
    /// └────┬─────┘                  └──┬───┘
    ///      │            ┌──┐           │
    ///  ┌───┴─────┐      │  │         ┌─┴──┐
    ///  │ BACKEND ├──────┤FW├─────────┤ DB │
    ///  └─────────┘      │  │         └────┘
    ///                   └──┘
    /// ```
    pub fn add_local_host_candidate(&mut self, address: SocketAddr) -> Result<(), Error> {
        self.add_local_as_host_candidate(address)?;

        Ok(())
    }

    #[tracing::instrument(level = "info", skip_all, fields(%id))]
    pub fn add_remote_candidate(&mut self, id: TId, candidate: String, now: Instant) {
        let candidate = match Candidate::from_sdp_string(&candidate) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!("Failed to parse candidate: {e}");
                return;
            }
        };

        if let Some(agent) = self.connections.agent_mut(id) {
            agent.add_remote_candidate(candidate.clone());
        }

        match candidate.kind() {
            CandidateKind::Host => {
                // Binding a TURN channel for host candidates does not make sense.
                // They are only useful to circumvent restrictive NATs in which case we are either talking to another relay candidate or a server-reflexive address.
                return;
            }

            CandidateKind::Relayed => {
                // Optimisatically try to bind the channel only on the same relay as the remote peer.
                if let Some(allocation) = self.same_relay_as_peer(id, &candidate) {
                    allocation.bind_channel(candidate.addr(), now);
                    return;
                }
            }
            CandidateKind::ServerReflexive | CandidateKind::PeerReflexive => {}
        }

        // In other cases, bind on all relays.
        for relay in self.connections.allowed_turn_servers(&id) {
            let Some(allocation) = self.allocations.get_mut(relay) else {
                continue;
            };

            allocation.bind_channel(candidate.addr(), now);
        }
    }

    /// Attempts to find the [`Allocation`] on the same relay as the remote's candidate.
    ///
    /// To do that, we need to check all candidates of each allocation and compare their IP.
    /// The same relay might be reachable over IPv4 and IPv6.
    #[must_use]
    fn same_relay_as_peer(&mut self, id: TId, candidate: &Candidate) -> Option<&mut Allocation> {
        self.allocations
            .iter_mut()
            .filter(|(relay, _)| {
                self.connections
                    .allowed_turn_servers(&id)
                    .any(|allowed| allowed == *relay)
            })
            .find_map(|(_, allocation)| {
                allocation
                    .current_candidates()
                    .any(|c| c.addr().ip() == candidate.addr().ip())
                    .then_some(allocation)
            })
    }

    /// Decapsulate an incoming packet.
    ///
    /// # Returns
    ///
    /// - `Ok(None)` if the packet was handled internally, for example, a response from a TURN server.
    /// - `Ok(Some)` if the packet was an encrypted wireguard packet from a peer.
    ///   The `Option` contains the connection on which the packet was decrypted.
    #[tracing::instrument(level = "debug", skip_all, fields(%from, num_bytes = %packet.len()))]
    pub fn decapsulate<'s>(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
        buffer: &'s mut [u8],
    ) -> Result<Option<(TId, MutableIpPacket<'s>)>, Error> {
        self.add_local_as_host_candidate(local)?;

        match self.bindings_try_handle(from, local, packet, now) {
            ControlFlow::Continue(()) => {}
            ControlFlow::Break(()) => return Ok(None),
        }

        let (from, packet, relayed) = match self.allocations_try_handle(from, local, packet, now) {
            ControlFlow::Continue(c) => c,
            ControlFlow::Break(()) => return Ok(None),
        };

        // For our agents, it is important what the initial "destination" of the packet was.
        let destination = relayed.map(|s| s.address()).unwrap_or(local);

        match self.agents_try_handle(from, destination, packet, now) {
            ControlFlow::Continue(()) => {}
            ControlFlow::Break(Ok(())) => return Ok(None),
            ControlFlow::Break(Err(e)) => return Err(e),
        };

        let (id, packet) =
            match self.connections_try_handle(from, local, packet, relayed, buffer, now) {
                ControlFlow::Continue(c) => c,
                ControlFlow::Break(Ok(())) => return Ok(None),
                ControlFlow::Break(Err(e)) => return Err(e),
            };

        Ok(Some((id, packet)))
    }

    /// Encapsulate an outgoing IP packet.
    ///
    /// Wireguard is an IP tunnel, so we "enforce" that only IP packets are sent through it.
    /// We say "enforce" an [`IpPacket`] can be created from an (almost) arbitrary byte buffer at virtually no cost.
    /// Nevertheless, using [`IpPacket`] in our API has good documentation value.
    #[tracing::instrument(level = "debug", skip_all, fields(id = %connection))]
    pub fn encapsulate<'s>(
        &'s mut self,
        connection: TId,
        packet: IpPacket<'_>,
        now: Instant,
    ) -> Result<Option<Transmit<'s>>, Error> {
        let conn = self
            .connections
            .get_established_mut(&connection)
            .ok_or(Error::NotConnected)?;

        // Must bail early if we don't have a socket yet to avoid running into WG timeouts.
        let socket = conn.peer_socket.ok_or(Error::NotConnected)?;

        let (header, payload) = self.buffer.as_mut().split_at_mut(4);

        let Some(packet) = conn.encapsulate(packet.packet(), payload)? else {
            return Ok(None);
        };

        match socket {
            PeerSocket::Direct {
                dest: remote,
                source,
            } => Ok(Some(Transmit {
                src: Some(source),
                dst: remote,
                payload: Cow::Borrowed(packet),
            })),
            PeerSocket::Relay { relay, dest: peer } => {
                let Some(allocation) = self.allocations.get_mut(&relay) else {
                    tracing::warn!(%relay, "No allocation");
                    return Ok(None);
                };
                let Some(total_length) = allocation.encode_to_slice(peer, packet, header, now)
                else {
                    tracing::warn!(%peer, "No channel");
                    return Ok(None);
                };

                // Safety: We split the slice before, but the borrow-checker doesn't allow us to re-borrow `self.buffer`.
                // Safety: `total_length` < `buffer.len()` because it is returned from `Tunn::encapsulate`.
                let channel_data_packet =
                    unsafe { slice::from_raw_parts(header.as_ptr(), total_length) };

                Ok(Some(Transmit {
                    src: None,
                    dst: relay,
                    payload: Cow::Borrowed(channel_data_packet),
                }))
            }
        }
    }

    /// Returns a pending [`Event`] from the pool.
    #[must_use]
    pub fn poll_event(&mut self) -> Option<Event<TId>> {
        self.pending_events.pop_front()
    }

    /// Returns, when [`Node::handle_timeout`] should be called next.
    ///
    /// This function only takes `&mut self` because it caches certain computations internally.
    /// The returned timestamp will **not** change unless other state is modified.
    #[must_use]
    pub fn poll_timeout(&mut self) -> Option<Instant> {
        let mut connection_timeout = None;

        for (_, c) in self.connections.iter_established_mut() {
            connection_timeout = earliest(connection_timeout, c.poll_timeout());
        }
        for b in self.bindings.values_mut() {
            connection_timeout = earliest(connection_timeout, b.poll_timeout());
        }
        for a in self.allocations.values_mut() {
            connection_timeout = earliest(connection_timeout, a.poll_timeout());
        }

        earliest(connection_timeout, self.next_rate_limiter_reset)
    }

    /// Advances time within the [`Node`].
    ///
    /// This function is the main "work-horse" outside of encapsulating or decapsulating network packets.
    /// Any significant state changes happen in here.
    ///
    /// ## Implementation note
    ///
    /// [`Node`] composes several other components that are also designed in a SANS-IO fashion.
    /// They all have similar functions like `poll_transmit`, `poll_event` etc.
    ///
    /// It might be tempting to e.g. define [`Node::poll_event`] as a composition of the lower-level `poll_event` functions.
    /// Counter-intuitively, this is not a good design.
    /// The reason is simple: An event generated by a lower-level components does not necessarily translate to an event for [`Node`].
    /// Instead, it might translate into something completely different, like a [`Transmit`].
    ///
    /// As such, it ends up being cleaner to "drain" all lower-level components of their events, transmits etc within this function.
    pub fn handle_timeout(&mut self, now: Instant) {
        self.bindings_and_allocations_drain_events();

        for (id, connection) in self.connections.iter_established_mut() {
            connection.handle_timeout(id, now, &mut self.allocations, &mut self.buffered_transmits);
        }

        for (id, connection) in self.connections.initial.iter_mut() {
            connection.handle_timeout(id, now);
        }

        for binding in self.bindings.values_mut() {
            binding.handle_timeout(now);
        }

        for allocation in self.allocations.values_mut() {
            allocation.handle_timeout(now);
        }

        let next_reset = *self.next_rate_limiter_reset.get_or_insert(now);

        if now >= next_reset {
            self.rate_limiter.reset_count();
            self.next_rate_limiter_reset = Some(now + Duration::from_secs(1));
        }

        self.connections.remove_failed(&mut self.pending_events);
    }

    /// Returns buffered data that needs to be sent on the socket.
    #[must_use]
    pub fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        for binding in self.bindings.values_mut() {
            if let Some(transmit) = binding.poll_transmit() {
                self.stats.stun_bytes_to_relays += transmit.payload.len();

                return Some(transmit);
            }
        }

        for allocation in self.allocations.values_mut() {
            if let Some(transmit) = allocation.poll_transmit() {
                self.stats.stun_bytes_to_relays += transmit.payload.len();

                return Some(transmit);
            }
        }

        self.buffered_transmits.pop_front()
    }

    #[must_use]
    #[allow(clippy::too_many_arguments)]
    fn init_connection(
        &mut self,
        mut agent: IceAgent,
        remote: PublicKey,
        key: [u8; 32],
        allowed_stun_servers: HashSet<SocketAddr>,
        allowed_turn_servers: HashSet<SocketAddr>,
        intent_sent_at: Instant,
        now: Instant,
    ) -> Connection {
        agent.handle_timeout(now);

        /// We set a Wireguard keep-alive to ensure the WG session doesn't timeout on an idle connection.
        ///
        /// Without such a timeout, using a tunnel after the REKEY_TIMEOUT requires handshaking a new session which delays the new application packet by 1 RTT.
        const WG_KEEP_ALIVE: Option<u16> = Some(10);

        Connection {
            agent,
            tunnel: Tunn::new(
                self.private_key.clone(),
                remote,
                Some(key),
                WG_KEEP_ALIVE,
                self.index.next(),
                Some(self.rate_limiter.clone()),
            ),
            stun_servers: allowed_stun_servers,
            turn_servers: allowed_turn_servers,
            next_timer_update: now,
            peer_socket: None,
            possible_sockets: Default::default(),
            stats: Default::default(),
            buffer: Box::new([0u8; MAX_UDP_SIZE]),
            intent_sent_at,
            is_failed: false,
            signalling_completed_at: now,
            remote_pub_key: remote,
        }
    }

    /// Attempt to add the `local` address as a host candidate.
    ///
    /// Receiving traffic on a certain interface means we at least have a connection to a relay via this interface.
    /// Thus, it is also a viable interface to attempt a connection to a gateway.
    fn add_local_as_host_candidate(&mut self, local: SocketAddr) -> Result<(), Error> {
        let host_candidate = Candidate::host(local, Protocol::Udp)?;

        let is_new = self.host_candidates.insert(host_candidate.clone());

        if !is_new {
            return Ok(());
        }

        for (id, agent) in self.connections.agents_mut() {
            let _span = info_span!("connection", %id).entered();

            add_local_candidate(id, agent, host_candidate.clone(), &mut self.pending_events);
        }

        Ok(())
    }

    #[must_use]
    fn bindings_try_handle(
        &mut self,
        from: SocketAddr,
        local: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> ControlFlow<()> {
        let Some(binding) = self.bindings.get_mut(&from) else {
            return ControlFlow::Continue(());
        };

        let handled = binding.handle_input(from, local, packet, now);

        if !handled {
            tracing::debug!("Packet was a STUN message but not accepted");
        }

        ControlFlow::Break(())
    }

    /// Tries to handle the packet using one of our [`Allocation`]s.
    #[must_use]
    fn allocations_try_handle<'p>(
        &mut self,
        from: SocketAddr,
        local: SocketAddr,
        packet: &'p [u8],
        now: Instant,
    ) -> ControlFlow<(), (SocketAddr, &'p [u8], Option<Socket>)> {
        // First, check whether the packet is from a known allocation.
        let Some(allocation) = self.allocations.get_mut(&from) else {
            return ControlFlow::Continue((from, packet, None));
        };

        // See <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2> for details on de-multiplexing.
        match packet.first() {
            Some(0..=3) => {
                if allocation.handle_input(from, local, packet, now) {
                    return ControlFlow::Break(());
                }

                tracing::debug!("Packet was a STUN message but not accepted");

                ControlFlow::Break(()) // Stop processing the packet.
            }
            Some(64..=79) => {
                if let Some((from, packet, socket)) = allocation.decapsulate(from, packet, now) {
                    return ControlFlow::Continue((from, packet, Some(socket)));
                }

                tracing::debug!("Packet was a channel data message but not accepted");

                ControlFlow::Break(()) // Stop processing the packet.
            }
            _ => ControlFlow::Continue((from, packet, None)),
        }
    }

    #[must_use]
    fn agents_try_handle(
        &mut self,
        from: SocketAddr,
        destination: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> ControlFlow<Result<(), Error>> {
        let Ok(message) = StunMessage::parse(packet) else {
            return ControlFlow::Continue(());
        };

        for (id, agent) in self.connections.agents_mut() {
            let _span = info_span!("connection", %id).entered();

            if agent.accepts_message(&message) {
                agent.handle_packet(
                    now,
                    StunPacket {
                        proto: Protocol::Udp,
                        source: from,
                        destination,
                        message,
                    },
                );

                return ControlFlow::Break(Ok(()));
            }
        }

        ControlFlow::Break(Err(Error::UnhandledStunMessage {
            num_agents: self.connections.len(),
        }))
    }

    #[must_use]
    fn connections_try_handle<'b>(
        &mut self,
        from: SocketAddr,
        local: SocketAddr,
        packet: &[u8],
        relayed: Option<Socket>,
        buffer: &'b mut [u8],
        now: Instant,
    ) -> ControlFlow<Result<(), Error>, (TId, MutableIpPacket<'b>)> {
        for (id, conn) in self.connections.iter_established_mut() {
            let _span = info_span!("connection", %id).entered();

            if !conn.accepts(from) {
                continue;
            }

            let handshake_complete_before_decapsulate = conn.wg_handshake_complete();

            let control_flow = conn.decapsulate(
                from,
                local,
                packet,
                relayed,
                buffer,
                &mut self.allocations,
                &mut self.buffered_transmits,
                now,
            );

            let handshake_complete_after_decapsulate = conn.wg_handshake_complete();

            // I can't think of a better way to detect this ...
            if !handshake_complete_before_decapsulate && handshake_complete_after_decapsulate {
                tracing::info!(duration_since_intent = ?conn.duration_since_intent(now), "Completed wireguard handshake");

                self.pending_events
                    .push_back(Event::ConnectionEstablished(id))
            }

            return match control_flow {
                ControlFlow::Continue(c) => ControlFlow::Continue((id, c)),
                ControlFlow::Break(b) => ControlFlow::Break(b),
            };
        }

        ControlFlow::Break(Err(Error::UnhandledPacket {
            num_tunnels: self.connections.iter_established_mut().count(),
        }))
    }

    fn bindings_and_allocations_drain_events(&mut self) {
        let binding_events = self.bindings.iter_mut().flat_map(|(server, binding)| {
            iter::from_fn(|| binding.poll_event().map(|e| (*server, e)))
        });
        let allocation_events = self
            .allocations
            .iter_mut()
            .flat_map(|(server, allocation)| {
                iter::from_fn(|| allocation.poll_event().map(|e| (*server, e)))
            });

        for (server, event) in binding_events.chain(allocation_events) {
            match event {
                CandidateEvent::New(candidate) => {
                    add_local_candidate_to_all(
                        server,
                        candidate,
                        &mut self.connections,
                        &mut self.pending_events,
                    );
                }
                CandidateEvent::Invalid(candidate) => {
                    for (id, agent) in self.connections.agents_mut() {
                        let _span = info_span!("connection", %id).entered();
                        agent.invalidate_candidate(&candidate);
                    }
                }
            }
        }
    }
}

impl<TId> Node<Client, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    /// Create a new connection indexed by the given ID.
    ///
    /// Out of all configured STUN and TURN servers, the connection will only use the ones provided here.
    /// The returned [`Offer`] must be passed to the remote via a signalling channel.
    #[tracing::instrument(level = "info", skip_all, fields(%id))]
    #[must_use]
    pub fn new_connection(
        &mut self,
        id: TId,
        allowed_stun_servers: HashSet<SocketAddr>,
        allowed_turn_servers: HashSet<(SocketAddr, String, String, String)>,
        intent_sent_at: Instant,
        now: Instant,
    ) -> Offer {
        if self.connections.initial.remove(&id).is_some() {
            tracing::info!("Replacing existing initial connection");
        };

        if self.connections.established.remove(&id).is_some() {
            tracing::info!("Replacing existing established connection");
        };

        self.upsert_stun_servers(&allowed_stun_servers, now);
        self.upsert_turn_servers(&allowed_turn_servers, now);

        let allowed_turn_servers = allowed_turn_servers
            .iter()
            .map(|(server, _, _, _)| server)
            .copied()
            .collect();

        let mut agent = IceAgent::new();
        agent.set_controlling(true);

        let session_key = Secret::new(random());
        let ice_creds = agent.local_credentials();

        let params = Offer {
            session_key: session_key.clone(),
            credentials: Credentials {
                username: ice_creds.ufrag.clone(),
                password: ice_creds.pass.clone(),
            },
        };

        let initial_connection = InitialConnection {
            agent,
            session_key,
            stun_servers: allowed_stun_servers,
            turn_servers: allowed_turn_servers,
            created_at: now,
            intent_sent_at,
            is_failed: false,
        };
        let duration_since_intent = initial_connection.duration_since_intent(now);

        let existing = self.connections.initial.insert(id, initial_connection);
        debug_assert!(existing.is_none());

        tracing::info!(?duration_since_intent, "Establishing new connection");

        params
    }

    /// Whether we have sent an [`Offer`] for this connection and are currently expecting an [`Answer`].
    pub fn is_expecting_answer(&self, id: TId) -> bool {
        self.connections.initial.contains_key(&id)
    }

    /// Accept an [`Answer`] from the remote for a connection previously created via [`Node::new_connection`].
    #[tracing::instrument(level = "info", skip_all, fields(%id))]
    pub fn accept_answer(&mut self, id: TId, remote: PublicKey, answer: Answer, now: Instant) {
        let Some(initial) = self.connections.initial.remove(&id) else {
            tracing::debug!("No initial connection state, ignoring answer"); // This can happen if the connection setup timed out.
            return;
        };

        let mut agent = initial.agent;
        agent.set_remote_credentials(IceCreds {
            ufrag: answer.credentials.username,
            pass: answer.credentials.password,
        });

        self.seed_agent_with_local_candidates(
            id,
            &mut agent,
            &initial.stun_servers,
            &initial.turn_servers,
        );

        let connection = self.init_connection(
            agent,
            remote,
            *initial.session_key.expose_secret(),
            initial.stun_servers,
            initial.turn_servers,
            initial.intent_sent_at,
            now,
        );
        let duration_since_intent = connection.duration_since_intent(now);

        let existing = self.connections.established.insert(id, connection);

        tracing::info!(?duration_since_intent, remote = %hex::encode(remote.as_bytes()), "Signalling protocol completed");

        debug_assert!(existing.is_none());
    }
}

impl<TId> Node<Server, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    /// Accept a new connection indexed by the given ID.
    ///
    /// Out of all configured STUN and TURN servers, the connection will only use the ones provided here.
    /// The returned [`Answer`] must be passed to the remote via a signalling channel.
    #[tracing::instrument(level = "info", skip_all, fields(%id))]
    #[must_use]
    pub fn accept_connection(
        &mut self,
        id: TId,
        offer: Offer,
        remote: PublicKey,
        allowed_stun_servers: HashSet<SocketAddr>,
        allowed_turn_servers: HashSet<(SocketAddr, String, String, String)>,
        now: Instant,
    ) -> Answer {
        debug_assert!(
            !self.connections.initial.contains_key(&id),
            "server to not use `initial_connections`"
        );

        if self.connections.established.remove(&id).is_some() {
            tracing::info!("Replacing existing established connection");
        };

        self.upsert_stun_servers(&allowed_stun_servers, now);
        self.upsert_turn_servers(&allowed_turn_servers, now);

        let allowed_turn_servers = allowed_turn_servers
            .iter()
            .map(|(server, _, _, _)| server)
            .copied()
            .collect();

        let mut agent = IceAgent::new();
        agent.set_controlling(false);
        agent.set_remote_credentials(IceCreds {
            ufrag: offer.credentials.username,
            pass: offer.credentials.password,
        });
        let answer = Answer {
            credentials: Credentials {
                username: agent.local_credentials().ufrag.clone(),
                password: agent.local_credentials().pass.clone(),
            },
        };

        self.seed_agent_with_local_candidates(
            id,
            &mut agent,
            &allowed_stun_servers,
            &allowed_turn_servers,
        );

        let connection = self.init_connection(
            agent,
            remote,
            *offer.session_key.expose_secret(),
            allowed_stun_servers,
            allowed_turn_servers,
            now, // Technically, this isn't fully correct because gateways don't send intents so we just use the current time.
            now,
        );
        let existing = self.connections.established.insert(id, connection);

        debug_assert!(existing.is_none());

        tracing::info!("Created new connection");

        answer
    }
}

impl<T, TId> Node<T, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    fn upsert_stun_servers(&mut self, servers: &HashSet<SocketAddr>, now: Instant) {
        for server in servers {
            if !self.bindings.contains_key(server) {
                tracing::info!(address = %server, "Adding new STUN server");

                self.bindings
                    .insert(*server, StunBinding::new(*server, now));
            }
        }
    }

    fn upsert_turn_servers(
        &mut self,
        servers: &HashSet<(SocketAddr, String, String, String)>,
        now: Instant,
    ) {
        for (server, username, password, realm) in servers {
            let Ok(username) = Username::new(username.to_owned()) else {
                tracing::debug!(%username, "Invalid TURN username");
                continue;
            };
            let Ok(realm) = Realm::new(realm.to_owned()) else {
                tracing::debug!(%realm, "Invalid TURN realm");
                continue;
            };

            if let Some(existing) = self.allocations.get_mut(server) {
                existing.update_credentials(username, password, realm, now);
                continue;
            }

            self.allocations.insert(
                *server,
                Allocation::new(*server, username, password.clone(), realm, now),
            );

            tracing::info!(address = %server, "Added new TURN server");
        }
    }

    fn seed_agent_with_local_candidates(
        &mut self,
        connection: TId,
        agent: &mut IceAgent,
        allowed_stun_servers: &HashSet<SocketAddr>,
        allowed_turn_servers: &HashSet<SocketAddr>,
    ) {
        for candidate in self.host_candidates.iter().cloned() {
            add_local_candidate(connection, agent, candidate, &mut self.pending_events);
        }

        for candidate in self.bindings.iter().filter_map(|(server, binding)| {
            let candidate = allowed_stun_servers
                .contains(server)
                .then(|| binding.candidate())??;

            Some(candidate)
        }) {
            add_local_candidate(
                connection,
                agent,
                candidate.clone(),
                &mut self.pending_events,
            );
        }

        for candidate in self
            .allocations
            .iter()
            .flat_map(|(server, allocation)| {
                allowed_turn_servers
                    .contains(server)
                    .then(|| allocation.current_candidates())
            })
            .flatten()
        {
            add_local_candidate(
                connection,
                agent,
                candidate.clone(),
                &mut self.pending_events,
            );
        }
    }
}

struct Connections<TId> {
    initial: HashMap<TId, InitialConnection>,
    established: HashMap<TId, Connection>,
}

impl<TId> Default for Connections<TId> {
    fn default() -> Self {
        Self {
            initial: Default::default(),
            established: Default::default(),
        }
    }
}

impl<TId> Connections<TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    fn remove_failed(&mut self, events: &mut VecDeque<Event<TId>>) {
        self.initial.retain(|id, conn| {
            if conn.is_failed {
                events.push_back(Event::ConnectionFailed(*id));
                return false;
            }

            true
        });

        self.established.retain(|id, conn| {
            if conn.is_failed {
                events.push_back(Event::ConnectionFailed(*id));
                return false;
            }

            true
        });
    }

    fn stats(&self) -> impl Iterator<Item = (TId, ConnectionStats)> + '_ {
        self.established.iter().map(move |(id, c)| (*id, c.stats))
    }

    fn agent_mut(&mut self, id: TId) -> Option<&mut IceAgent> {
        let maybe_initial_connection = self.initial.get_mut(&id).map(|i| &mut i.agent);
        let maybe_established_connection = self.established.get_mut(&id).map(|c| &mut c.agent);

        maybe_initial_connection.or(maybe_established_connection)
    }

    fn agents_mut(&mut self) -> impl Iterator<Item = (TId, &mut IceAgent)> {
        let initial_agents = self.initial.iter_mut().map(|(id, c)| (*id, &mut c.agent));
        let negotiated_agents = self
            .established
            .iter_mut()
            .map(|(id, c)| (*id, &mut c.agent));

        initial_agents.chain(negotiated_agents)
    }

    fn get_established_mut(&mut self, id: &TId) -> Option<&mut Connection> {
        self.established.get_mut(id)
    }

    fn allowed_turn_servers(&self, id: &TId) -> impl Iterator<Item = &SocketAddr> + '_ {
        let initial = self
            .initial
            .get(id)
            .into_iter()
            .flat_map(|c| c.turn_servers.iter());
        let established = self
            .established
            .get(id)
            .into_iter()
            .flat_map(|c| c.turn_servers.iter());

        initial.chain(established)
    }

    fn iter_established(&self) -> impl Iterator<Item = (TId, &Connection)> {
        self.established.iter().map(|(id, conn)| (*id, conn))
    }

    fn iter_established_mut(&mut self) -> impl Iterator<Item = (TId, &mut Connection)> {
        self.established.iter_mut().map(|(id, conn)| (*id, conn))
    }

    fn len(&self) -> usize {
        self.initial.len() + self.established.len()
    }
}

/// Wraps the message as a channel data message via the relay, iff:
///
/// - `relay` is in fact a relay
/// - We have an allocation on the relay
/// - There is a channel bound to the provided peer
fn encode_as_channel_data(
    relay: SocketAddr,
    dest: SocketAddr,
    contents: &[u8],
    allocations: &mut HashMap<SocketAddr, Allocation>,
    now: Instant,
) -> Result<Transmit<'static>, EncodeError> {
    let allocation = allocations
        .get_mut(&relay)
        .ok_or(EncodeError::NoAllocation)?;
    let payload = allocation
        .encode_to_vec(dest, contents, now)
        .ok_or(EncodeError::NoChannel)?;

    Ok(Transmit {
        src: None,
        dst: relay,
        payload: Cow::Owned(payload),
    })
}

#[derive(Debug)]
enum EncodeError {
    NoAllocation,
    NoChannel,
}

fn add_local_candidate_to_all<TId>(
    server: SocketAddr,
    candidate: Candidate,
    connections: &mut Connections<TId>,
    pending_events: &mut VecDeque<Event<TId>>,
) where
    TId: Copy + fmt::Display,
{
    let initial_connections = connections
        .initial
        .iter_mut()
        .map(|(id, c)| (*id, &c.stun_servers, &c.turn_servers, &mut c.agent));
    let established_connections = connections
        .established
        .iter_mut()
        .map(|(id, c)| (*id, &c.stun_servers, &c.turn_servers, &mut c.agent));

    for (id, allowed_stun, allowed_turn, agent) in
        initial_connections.chain(established_connections)
    {
        let _span = info_span!("connection", %id).entered();

        match candidate.kind() {
            CandidateKind::ServerReflexive => {
                if (!allowed_stun.contains(&server)) && (!allowed_turn.contains(&server)) {
                    tracing::debug!(%server, ?allowed_stun, ?allowed_turn, "Not adding srflx candidate");
                    continue;
                }
            }
            CandidateKind::Relayed => {
                if !allowed_turn.contains(&server) {
                    tracing::debug!(%server, ?allowed_turn, "Not adding relay candidate");

                    continue;
                }
            }
            CandidateKind::PeerReflexive | CandidateKind::Host => continue,
        }

        add_local_candidate(id, agent, candidate.clone(), pending_events);
    }
}

fn add_local_candidate<TId>(
    id: TId,
    agent: &mut IceAgent,
    candidate: Candidate,
    pending_events: &mut VecDeque<Event<TId>>,
) where
    TId: fmt::Display,
{
    let is_new = agent.add_local_candidate(candidate.clone());

    if is_new {
        pending_events.push_back(Event::SignalIceCandidate {
            connection: id,
            candidate: candidate.to_sdp_string(),
        })
    }
}

pub struct Offer {
    /// The Wireguard session key for a connection.
    pub session_key: Secret<[u8; 32]>,
    pub credentials: Credentials,
}

pub struct Answer {
    pub credentials: Credentials,
}

pub struct Credentials {
    /// The ICE username (ufrag).
    pub username: String,
    /// The ICE password.
    pub password: String,
}

#[derive(Debug, PartialEq)]
pub enum Event<TId> {
    /// Signal the ICE candidate to the remote via the signalling channel.
    ///
    /// Candidates are in SDP format although this may change and should be considered an implementation detail of the application.
    SignalIceCandidate {
        connection: TId,
        candidate: String,
    },
    ConnectionEstablished(TId),

    /// We failed to establish a connection.
    ///
    /// All state associated with the connection has been cleared.
    ConnectionFailed(TId),
}

#[derive(Debug)]
pub struct Transmit<'a> {
    /// The local interface from which this packet should be sent.
    ///
    /// If `None`, it can be sent from any interface.
    /// Typically, this will be `None` for any message that needs to be sent to a relay.
    ///
    /// For all direct communication with another peer, this will be set and must be honored.
    pub src: Option<SocketAddr>,
    /// The remote the packet should be sent to.
    pub dst: SocketAddr,
    /// The data that should be sent.
    pub payload: Cow<'a, [u8]>,
}

impl<'a> Transmit<'a> {
    pub fn into_owned(self) -> Transmit<'static> {
        Transmit {
            src: self.src,
            dst: self.dst,
            payload: Cow::Owned(self.payload.into_owned()),
        }
    }
}

#[derive(Debug, PartialEq)]
pub(crate) enum CandidateEvent {
    New(Candidate),
    Invalid(Candidate),
}

struct InitialConnection {
    agent: IceAgent,
    session_key: Secret<[u8; 32]>,
    stun_servers: HashSet<SocketAddr>,
    turn_servers: HashSet<SocketAddr>,

    created_at: Instant,
    intent_sent_at: Instant,

    is_failed: bool,
}

impl InitialConnection {
    #[tracing::instrument(level = "debug", skip_all, fields(%id))]
    fn handle_timeout<TId>(&mut self, id: TId, now: Instant)
    where
        TId: fmt::Display,
    {
        if now.duration_since(self.created_at) >= HANDSHAKE_TIMEOUT {
            tracing::info!("Connection setup timed out (no answer received)");
            self.is_failed = true;
        }
    }

    fn duration_since_intent(&self, now: Instant) -> Duration {
        now.duration_since(self.intent_sent_at)
    }
}

struct Connection {
    agent: IceAgent,

    remote_pub_key: PublicKey,

    tunnel: Tunn,
    next_timer_update: Instant,

    // When this is `Some`, we are connected.
    peer_socket: Option<PeerSocket>,
    // Socket addresses from which we might receive data (even before we are connected).
    possible_sockets: HashSet<SocketAddr>,

    stun_servers: HashSet<SocketAddr>,
    turn_servers: HashSet<SocketAddr>,

    stats: ConnectionStats,

    buffer: Box<[u8; MAX_UDP_SIZE]>,
    intent_sent_at: Instant,

    is_failed: bool,

    signalling_completed_at: Instant,
}

/// The socket of the peer we are connected to.
#[derive(Debug, PartialEq, Clone, Copy)]
enum PeerSocket {
    Direct {
        source: SocketAddr,
        dest: SocketAddr,
    },
    Relay {
        relay: SocketAddr,
        dest: SocketAddr,
    },
}

impl PeerSocket {
    fn our_socket(&self) -> SocketAddr {
        match self {
            PeerSocket::Direct { source, .. } => *source,
            PeerSocket::Relay { relay, .. } => *relay,
        }
    }
}

impl Connection {
    /// Checks if we want to accept a packet from a certain address.
    ///
    /// Whilst we establish connections, we may see traffic from a certain address, prior to the negotiation being fully complete.
    /// We already want to accept that traffic and not throw it away.
    #[must_use]
    fn accepts(&self, addr: SocketAddr) -> bool {
        let from_connected_remote = self.peer_socket.is_some_and(|r| match r {
            PeerSocket::Direct { dest, .. } => dest == addr,
            PeerSocket::Relay { dest, .. } => dest == addr,
        });
        let from_possible_remote = self.possible_sockets.contains(&addr);

        from_connected_remote || from_possible_remote
    }

    fn wg_handshake_complete(&self) -> bool {
        self.tunnel.time_since_last_handshake().is_some()
    }

    fn duration_since_intent(&self, now: Instant) -> Duration {
        now.duration_since(self.intent_sent_at)
    }

    fn set_remote_from_wg_activity(
        &mut self,
        local: SocketAddr,
        dest: SocketAddr,
        relay_socket: Option<Socket>,
    ) -> PeerSocket {
        let remote_socket = match relay_socket {
            Some(relay_socket) => PeerSocket::Relay {
                relay: relay_socket.server(),
                dest,
            },
            None => PeerSocket::Direct {
                source: local,
                dest,
            },
        };

        if self.peer_socket != Some(remote_socket) {
            tracing::debug!(old = ?self.peer_socket, new = ?remote_socket, "Updating remote socket from WG activity");
            self.peer_socket = Some(remote_socket);
        }

        remote_socket
    }

    #[must_use]
    fn poll_timeout(&mut self) -> Option<Instant> {
        let agent_timeout = self.agent.poll_timeout();
        let next_wg_timer = Some(self.next_timer_update);
        let candidate_timeout = self.candidate_timeout();

        earliest(agent_timeout, earliest(next_wg_timer, candidate_timeout))
    }

    fn candidate_timeout(&self) -> Option<Instant> {
        if !self.agent.remote_candidates().is_empty() {
            return None;
        }

        Some(self.signalling_completed_at + CANDIDATE_TIMEOUT)
    }

    #[tracing::instrument(level = "info", skip_all, fields(%id))]
    fn handle_timeout<TId>(
        &mut self,
        id: TId,
        now: Instant,
        allocations: &mut HashMap<SocketAddr, Allocation>,
        transmits: &mut VecDeque<Transmit<'static>>,
    ) where
        TId: fmt::Display + Copy,
    {
        self.agent.handle_timeout(now);

        if self
            .candidate_timeout()
            .is_some_and(|timeout| now >= timeout)
        {
            tracing::info!("Connection failed (no candidates received)");
            self.is_failed = true;
            return;
        }

        // TODO: `boringtun` is impure because it calls `Instant::now`.

        if now >= self.next_timer_update {
            self.next_timer_update = now + Duration::from_secs(1);

            // Don't update wireguard timers until we are connected.
            let Some(peer_socket) = self.peer_socket else {
                return;
            };

            /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
            ///
            /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
            const MAX_SCRATCH_SPACE: usize = 148;

            let mut buf = [0u8; MAX_SCRATCH_SPACE];

            match self.tunnel.update_timers(&mut buf) {
                TunnResult::Done => {}
                TunnResult::Err(WireGuardError::ConnectionExpired) => {
                    tracing::info!("Connection failed (wireguard tunnel expired)");
                    self.is_failed = true;
                }
                TunnResult::Err(e) => {
                    tracing::warn!(?e);
                }
                TunnResult::WriteToNetwork(b) => {
                    transmits.extend(make_owned_transmit(peer_socket, b, allocations, now));
                }
                _ => panic!("Unexpected result from update_timers"),
            };
        }

        while let Some(event) = self.agent.poll_event() {
            match event {
                IceAgentEvent::DiscoveredRecv { source, .. } => {
                    self.possible_sockets.insert(source);
                }
                IceAgentEvent::IceConnectionStateChange(IceConnectionState::Disconnected) => {
                    tracing::info!("Connection failed (ICE timeout)");
                    self.is_failed = true;
                }
                IceAgentEvent::NominatedSend {
                    destination,
                    source,
                    ..
                } => {
                    let candidate = self
                        .local_candidate(source)
                        .expect("to only nominate existing candidates");

                    let remote_socket = match candidate.kind() {
                        CandidateKind::Relayed => {
                            let relay = allocations.iter().find_map(|(relay, allocation)| {
                                allocation.has_socket(source).then_some(*relay)
                            });

                            let Some(relay) = relay else {
                                debug_assert!(
                                    false,
                                    "Should only nominate candidates from known relays"
                                );
                                continue;
                            };

                            PeerSocket::Relay {
                                relay,
                                dest: destination,
                            }
                        }
                        CandidateKind::ServerReflexive | CandidateKind::Host => {
                            PeerSocket::Direct {
                                dest: destination,
                                source,
                            }
                        }
                        CandidateKind::PeerReflexive => {
                            unreachable!("local candidate is never `PeerReflexive`")
                        }
                    };

                    if self.peer_socket != Some(remote_socket) {
                        tracing::info!(old = ?self.peer_socket, new = ?remote_socket, duration_since_intent = ?self.duration_since_intent(now), "Updating remote socket");
                        self.peer_socket = Some(remote_socket);

                        self.invalidate_candiates();
                        self.force_handshake(allocations, transmits, now);
                    }
                }
                _ => {}
            }
        }

        while let Some(transmit) = self.agent.poll_transmit() {
            let source = transmit.source;
            let dst = transmit.destination;
            let packet = transmit.contents;

            // Check if `str0m` wants us to send from a "remote" socket, i.e. one that we allocated with a relay.
            let allocation = allocations
                .iter_mut()
                .find(|(_, allocation)| allocation.has_socket(source));

            let Some((relay, allocation)) = allocation else {
                self.stats.stun_bytes_to_peer_direct += packet.len();

                // `source` did not match any of our allocated sockets, must be a local one then!
                transmits.push_back(Transmit {
                    src: Some(source),
                    dst,
                    payload: Cow::Owned(packet.into()),
                });
                continue;
            };

            // Payload should be sent from a "remote socket", let's wrap it in a channel data message!
            let Some(channel_data) = allocation.encode_to_vec(dst, &packet, now) else {
                // Unlikely edge-case, drop the packet and continue.
                tracing::trace!(%relay, peer = %dst, "Dropping packet because allocation does not offer a channel to peer");
                continue;
            };

            self.stats.stun_bytes_to_peer_relayed += channel_data.len();

            transmits.push_back(Transmit {
                src: None,
                dst: *relay,
                payload: Cow::Owned(channel_data),
            });
        }
    }

    fn encapsulate<'b>(
        &mut self,
        packet: &[u8],
        buffer: &'b mut [u8],
    ) -> Result<Option<&'b [u8]>, Error> {
        let len = match self.tunnel.encapsulate(packet, buffer) {
            TunnResult::Done => return Ok(None),
            TunnResult::Err(e) => return Err(Error::Encapsulate(e)),
            TunnResult::WriteToNetwork(packet) => packet.len(),
            TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                unreachable!("never returned from encapsulate")
            }
        };

        Ok(Some(&buffer[..len]))
    }

    #[allow(clippy::too_many_arguments)]
    fn decapsulate<'b>(
        &mut self,
        from: SocketAddr,
        local: SocketAddr,
        packet: &[u8],
        relayed: Option<Socket>,
        buffer: &'b mut [u8],
        allocations: &mut HashMap<SocketAddr, Allocation>,
        transmits: &mut VecDeque<Transmit<'static>>,
        now: Instant,
    ) -> ControlFlow<Result<(), Error>, MutableIpPacket<'b>> {
        match self.tunnel.decapsulate(None, packet, buffer) {
            TunnResult::Done => ControlFlow::Break(Ok(())),
            TunnResult::Err(e) => ControlFlow::Break(Err(Error::Decapsulate(e))),

            // For WriteToTunnel{V4,V6}, boringtun returns the source IP of the packet that was tunneled to us.
            // I am guessing this was done for convenience reasons.
            // In our API, we parse the packets directly as an IpPacket.
            // Thus, the caller can query whatever data they'd like, not just the source IP so we don't return it in addition.
            TunnResult::WriteToTunnelV4(packet, ip) => {
                self.set_remote_from_wg_activity(local, from, relayed);

                let ipv4_packet =
                    MutableIpv4Packet::new(packet).expect("boringtun verifies validity");
                debug_assert_eq!(ipv4_packet.get_source(), ip);

                ControlFlow::Continue(ipv4_packet.into())
            }
            TunnResult::WriteToTunnelV6(packet, ip) => {
                self.set_remote_from_wg_activity(local, from, relayed);

                let ipv6_packet =
                    MutableIpv6Packet::new(packet).expect("boringtun verifies validity");
                debug_assert_eq!(ipv6_packet.get_source(), ip);

                ControlFlow::Continue(ipv6_packet.into())
            }

            // During normal operation, i.e. when the tunnel is active, decapsulating a packet straight yields the decrypted packet.
            // However, in case `Tunn` has buffered packets, they may be returned here instead.
            // This should be fairly rare which is why we just allocate these and return them from `poll_transmit` instead.
            // Overall, this results in a much nicer API for our caller and should not affect performance.
            TunnResult::WriteToNetwork(bytes) => {
                let socket = self.set_remote_from_wg_activity(local, from, relayed);

                transmits.extend(make_owned_transmit(socket, bytes, allocations, now));

                while let TunnResult::WriteToNetwork(packet) =
                    self.tunnel.decapsulate(None, &[], self.buffer.as_mut())
                {
                    transmits.extend(make_owned_transmit(socket, packet, allocations, now));
                }

                ControlFlow::Break(Ok(()))
            }
        }
    }

    fn force_handshake(
        &mut self,
        allocations: &mut HashMap<SocketAddr, Allocation>,
        transmits: &mut VecDeque<Transmit<'static>>,
        now: Instant,
    ) {
        /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
        ///
        /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
        const MAX_SCRATCH_SPACE: usize = 148;

        let mut buf = [0u8; MAX_SCRATCH_SPACE];

        let TunnResult::WriteToNetwork(bytes) =
            self.tunnel.format_handshake_initiation(&mut buf, true)
        else {
            return;
        };

        let socket = self
            .peer_socket
            .expect("cannot force handshake without socket");

        transmits.extend(make_owned_transmit(socket, bytes, allocations, now));
    }

    /// Invalidates all local candidates with a lower or equal priority compared to the nominated one.
    ///
    /// Each time we nominate a candidate pair, we don't really want to keep all the others active because it creates a lot of noise.
    /// At the same time, we want to retain trickle ICE and allow the ICE agent to find a _better_ pair, hence we invalidate by priority.
    #[tracing::instrument(level = "debug", skip_all, fields(nominated_prio))]
    fn invalidate_candiates(&mut self) {
        let Some(socket) = self.peer_socket else {
            return;
        };

        let Some(nominated) = self.local_candidate(socket.our_socket()).cloned() else {
            return;
        };

        Span::current().record("nominated_prio", field::display(&nominated.prio()));

        let irrelevant_candidates = self
            .agent
            .local_candidates()
            .iter()
            .filter(|c| c.prio() <= nominated.prio() && c != &&nominated)
            .cloned()
            .collect::<Vec<_>>();

        for candidate in irrelevant_candidates {
            self.agent.invalidate_candidate(&candidate);
        }
    }

    fn local_candidate(&self, source: SocketAddr) -> Option<&Candidate> {
        self.agent
            .local_candidates()
            .iter()
            .find(|c| c.addr() == source)
    }
}

#[must_use]
fn make_owned_transmit(
    socket: PeerSocket,
    message: &[u8],
    allocations: &mut HashMap<SocketAddr, Allocation>,
    now: Instant,
) -> Option<Transmit<'static>> {
    let transmit = match socket {
        PeerSocket::Direct {
            dest: remote,
            source,
        } => Transmit {
            src: Some(source),
            dst: remote,
            payload: Cow::Owned(message.into()),
        },
        PeerSocket::Relay { relay, dest: peer } => {
            encode_as_channel_data(relay, peer, message, allocations, now).ok()?
        }
    };

    Some(transmit)
}
