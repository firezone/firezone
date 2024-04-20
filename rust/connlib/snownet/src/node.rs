use crate::allocation::{Allocation, Socket};
use crate::index::IndexLfsr;
use crate::ringbuffer::RingBuffer;
use crate::stats::{ConnectionStats, NodeStats};
use crate::stun_binding::StunBinding;
use crate::utils::earliest;
use boringtun::noise::errors::WireGuardError;
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::PublicKey;
use boringtun::{noise::rate_limiter::RateLimiter, x25519::StaticSecret};
use core::{fmt, slice};
use ip_packet::ipv4::MutableIpv4Packet;
use ip_packet::ipv6::MutableIpv6Packet;
use ip_packet::{IpPacket, MutableIpPacket, Packet as _};
use rand::random;
use secrecy::{ExposeSecret, Secret};
use std::borrow::Cow;
use std::hash::Hash;
use std::marker::PhantomData;
use std::mem;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    net::SocketAddr,
    sync::Arc,
};
use str0m::ice::{IceAgent, IceAgentEvent, IceCreds, StunMessage, StunPacket};
use str0m::net::Protocol;
use str0m::{Candidate, CandidateKind, IceConnectionState};
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
pub type ServerNode<TId, RId> = Node<Server, TId, RId>;
/// Manages a set of wireguard connections for a client.
pub type ClientNode<TId, RId> = Node<Client, TId, RId>;

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
///
/// A [`Node`] is generic over three things:
/// - `T`: The mode it is operating in, either [`Client`] or [`Server`].
/// - `TId`: The type to use for uniquely identifying connections.
/// - `RId`: The type to use for uniquely identifying relays.
///
/// We favor these generic parameters over having our own IDs to avoid mapping back and forth in upper layers.
pub struct Node<T, TId, RId> {
    private_key: StaticSecret,
    index: IndexLfsr,
    rate_limiter: Arc<RateLimiter>,
    host_candidates: HashSet<Candidate>,
    buffered_transmits: VecDeque<Transmit<'static>>,

    next_rate_limiter_reset: Option<Instant>,

    bindings: HashMap<SocketAddr, StunBinding>,
    allocations: HashMap<RId, Allocation>,

    connections: Connections<TId, RId>,
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

impl<T, TId, RId> Node<T, TId, RId>
where
    TId: Eq + Hash + Copy + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + fmt::Debug + fmt::Display,
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

    pub fn connection_id(&self, key: PublicKey) -> Option<TId> {
        self.connections.iter_established().find_map(|(id, c)| {
            (c.remote_pub_key == key && c.tunnel.time_since_last_handshake().is_some())
                .then_some(id)
        })
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
                if let Some(allocation) = self.same_relay_as_peer(&candidate) {
                    allocation.bind_channel(candidate.addr(), now);
                    return;
                }
            }
            CandidateKind::ServerReflexive | CandidateKind::PeerReflexive => {}
        }

        // In other cases, bind on all relays.
        for allocation in self.allocations.values_mut() {
            allocation.bind_channel(candidate.addr(), now);
        }
    }

    #[tracing::instrument(level = "info", skip_all, fields(%id))]
    pub fn remove_remote_candidate(&mut self, id: TId, candidate: String) {
        let candidate = match Candidate::from_sdp_string(&candidate) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!("Failed to parse candidate: {e}");
                return;
            }
        };

        if let Some(agent) = self.connections.agent_mut(id) {
            agent.invalidate_candidate(&candidate);
        }
    }

    /// Attempts to find the [`Allocation`] on the same relay as the remote's candidate.
    ///
    /// To do that, we need to check all candidates of each allocation and compare their IP.
    /// The same relay might be reachable over IPv4 and IPv6.
    #[must_use]
    fn same_relay_as_peer(&mut self, candidate: &Candidate) -> Option<&mut Allocation> {
        self.allocations.iter_mut().find_map(|(_, allocation)| {
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

        let (id, packet) = match self.connections_try_handle(from, packet, buffer, now) {
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
        let socket = conn.socket().ok_or(Error::NotConnected)?;

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
                let Some(allocation) = self.allocations.get(&relay) else {
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
                    dst: allocation.server(),
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
            connection.handle_timeout(
                id,
                now,
                &mut self.allocations,
                &mut self.buffered_transmits,
                &mut self.pending_events,
            );
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

    pub fn update_relays(
        &mut self,
        to_remove: HashSet<RId>,
        to_add: &HashSet<(RId, SocketAddr, String, String, String)>,
        now: Instant,
    ) {
        // First, invalidate all candidates from relays that we should stop using.
        for id in to_remove {
            let Some(allocation) = self.allocations.remove(&id) else {
                continue;
            };

            for (id, agent) in self.connections.agents_mut() {
                let _span = info_span!("connection", %id).entered();

                for candidate in allocation
                    .current_candidates()
                    .filter(|c| c.kind() == CandidateKind::Relayed)
                {
                    agent.invalidate_candidate(&candidate);
                }
            }
        }

        // Second, upsert all new relays.
        for (id, server, username, password, realm) in to_add {
            let Ok(username) = Username::new(username.to_owned()) else {
                tracing::debug!(%username, "Invalid TURN username");
                continue;
            };
            let Ok(realm) = Realm::new(realm.to_owned()) else {
                tracing::debug!(%realm, "Invalid TURN realm");
                continue;
            };

            if let Some(existing) = self.allocations.get_mut(id) {
                existing.update_credentials(*server, username, password, realm, now);
                continue;
            }

            self.allocations.insert(
                *id,
                Allocation::new(*server, username, password.clone(), realm, now),
            );

            tracing::info!(%id, address = %server, "Added new TURN server");
        }
    }

    #[must_use]
    #[allow(clippy::too_many_arguments)]
    fn init_connection(
        &mut self,
        mut agent: IceAgent,
        remote: PublicKey,
        key: [u8; 32],
        intent_sent_at: Instant,
        now: Instant,
    ) -> Connection<RId> {
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
            next_timer_update: now,
            stats: Default::default(),
            buffer: Box::new([0u8; MAX_UDP_SIZE]),
            intent_sent_at,
            signalling_completed_at: now,
            remote_pub_key: remote,
            state: ConnectionState::Connecting {
                possible_sockets: HashSet::default(),
                buffered: RingBuffer::new(10),
            },
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
    ///
    /// This function is in the hot-path of packet processing and thus must be as efficient as possible.
    /// Even look-ups in [`HashMap`]s and linear searches across small lists are expensive at this point.
    /// Thus, we use the first byte of the message as a heuristic for whether we should attempt to handle it here.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2> for details on de-multiplexing.
    ///
    /// This heuristic might fail because we are also handling wireguard packets.
    /// Those are fully encrypted and thus any byte pattern may appear at the front of the packet.
    /// We can detect this by further checking the origin of the packet.
    #[must_use]
    #[allow(clippy::type_complexity)]
    fn allocations_try_handle<'p>(
        &mut self,
        from: SocketAddr,
        local: SocketAddr,
        packet: &'p [u8],
        now: Instant,
    ) -> ControlFlow<(), (SocketAddr, &'p [u8], Option<Socket>)> {
        match packet.first().copied() {
            // STUN method range
            Some(0..=3) => {
                let Some(allocation) = self.allocations.values_mut().find(|a| a.server() == from)
                else {
                    // False-positive, continue processing packet elsewhere
                    return ControlFlow::Continue((from, packet, None));
                };

                if allocation.handle_input(from, local, packet, now) {
                    // Successfully handled the packet
                    return ControlFlow::Break(());
                }

                tracing::debug!("Packet was a STUN message but not accepted");

                ControlFlow::Break(()) // Stop processing the packet.
            }
            // Channel data number range
            Some(64..=79) => {
                let Some(allocation) = self.allocations.values_mut().find(|a| a.server() == from)
                else {
                    // False-positive, continue processing packet elsewhere
                    return ControlFlow::Continue((from, packet, None));
                };

                if let Some((from, packet, socket)) = allocation.decapsulate(from, packet, now) {
                    // Successfully handled the packet and decapsulated the channel data message.
                    // Continue processing with the _unwrapped_ packet.
                    return ControlFlow::Continue((from, packet, Some(socket)));
                }

                tracing::debug!("Packet was a channel data message but not accepted");

                ControlFlow::Break(()) // Stop processing the packet.
            }
            // Byte is in a different range? Move on with processing the packet.
            Some(_) | None => ControlFlow::Continue((from, packet, None)),
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
        packet: &[u8],
        buffer: &'b mut [u8],
        now: Instant,
    ) -> ControlFlow<Result<(), Error>, (TId, MutableIpPacket<'b>)> {
        for (id, conn) in self.connections.iter_established_mut() {
            let _span = info_span!("connection", %id).entered();

            if !conn.accepts(&from) {
                continue;
            }

            let handshake_complete_before_decapsulate = conn.wg_handshake_complete();

            let control_flow = conn.decapsulate(
                packet,
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
        let binding_events = self
            .bindings
            .values_mut()
            .flat_map(|binding| binding.poll_event());
        let allocation_events = self
            .allocations
            .values_mut()
            .flat_map(|allocation| allocation.poll_event());

        for event in binding_events.chain(allocation_events) {
            match event {
                CandidateEvent::New(candidate) => {
                    add_local_candidate_to_all(
                        candidate,
                        &mut self.connections,
                        &mut self.pending_events,
                    );
                }
                CandidateEvent::Invalid(candidate) => {
                    for (id, agent) in self.connections.agents_mut() {
                        let _span = info_span!("connection", %id).entered();

                        remove_local_candidate(id, agent, &candidate, &mut self.pending_events);
                    }
                }
            }
        }
    }
}

impl<TId, RId> Node<Client, TId, RId>
where
    TId: Eq + Hash + Copy + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + fmt::Debug + fmt::Display,
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
        stun_servers: HashSet<SocketAddr>,
        turn_servers: HashSet<(RId, SocketAddr, String, String, String)>,
        intent_sent_at: Instant,
        now: Instant,
    ) -> Offer {
        if self.connections.initial.remove(&id).is_some() {
            tracing::info!("Replacing existing initial connection");
        };

        if self.connections.established.remove(&id).is_some() {
            tracing::info!("Replacing existing established connection");
        };

        self.upsert_stun_servers(&stun_servers, now);
        self.update_relays(HashSet::default(), &turn_servers, now);

        let mut agent = IceAgent::new();
        agent.set_controlling(true);
        agent.set_max_candidate_pairs(300);

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

        self.seed_agent_with_local_candidates(id, &mut agent);

        let connection = self.init_connection(
            agent,
            remote,
            *initial.session_key.expose_secret(),
            initial.intent_sent_at,
            now,
        );
        let duration_since_intent = connection.duration_since_intent(now);

        let existing = self.connections.established.insert(id, connection);

        tracing::info!(?duration_since_intent, remote = %hex::encode(remote.as_bytes()), "Signalling protocol completed");

        debug_assert!(existing.is_none());
    }
}

impl<TId, RId> Node<Server, TId, RId>
where
    TId: Eq + Hash + Copy + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + fmt::Debug + fmt::Display,
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
        stun_servers: HashSet<SocketAddr>,
        turn_servers: HashSet<(RId, SocketAddr, String, String, String)>,
        now: Instant,
    ) -> Answer {
        debug_assert!(
            !self.connections.initial.contains_key(&id),
            "server to not use `initial_connections`"
        );

        if self.connections.established.remove(&id).is_some() {
            tracing::info!("Replacing existing established connection");
        };

        self.upsert_stun_servers(&stun_servers, now);
        self.update_relays(HashSet::default(), &turn_servers, now);

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

        self.seed_agent_with_local_candidates(id, &mut agent);

        let connection = self.init_connection(
            agent,
            remote,
            *offer.session_key.expose_secret(),
            now, // Technically, this isn't fully correct because gateways don't send intents so we just use the current time.
            now,
        );
        let existing = self.connections.established.insert(id, connection);

        debug_assert!(existing.is_none());

        tracing::info!("Created new connection");

        answer
    }
}

impl<T, TId, RId> Node<T, TId, RId>
where
    TId: Eq + Hash + Copy + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + fmt::Debug + fmt::Display,
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

    fn seed_agent_with_local_candidates(&mut self, connection: TId, agent: &mut IceAgent) {
        for candidate in self.host_candidates.iter().cloned() {
            add_local_candidate(connection, agent, candidate, &mut self.pending_events);
        }

        for candidate in self
            .bindings
            .values()
            .filter_map(|binding| binding.candidate())
        {
            add_local_candidate(
                connection,
                agent,
                candidate.clone(),
                &mut self.pending_events,
            );
        }

        for candidate in self
            .allocations
            .values()
            .flat_map(|allocation| allocation.current_candidates())
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

struct Connections<TId, RId> {
    initial: HashMap<TId, InitialConnection>,
    established: HashMap<TId, Connection<RId>>,
}

impl<TId, RId> Default for Connections<TId, RId> {
    fn default() -> Self {
        Self {
            initial: Default::default(),
            established: Default::default(),
        }
    }
}

impl<TId, RId> Connections<TId, RId>
where
    TId: Eq + Hash + Copy + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + fmt::Debug + fmt::Display,
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
            if conn.is_failed() {
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

    fn get_established_mut(&mut self, id: &TId) -> Option<&mut Connection<RId>> {
        self.established.get_mut(id)
    }

    fn iter_established(&self) -> impl Iterator<Item = (TId, &Connection<RId>)> {
        self.established.iter().map(|(id, conn)| (*id, conn))
    }

    fn iter_established_mut(&mut self) -> impl Iterator<Item = (TId, &mut Connection<RId>)> {
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
fn encode_as_channel_data<RId>(
    relay: RId,
    dest: SocketAddr,
    contents: &[u8],
    allocations: &mut HashMap<RId, Allocation>,
    now: Instant,
) -> Result<Transmit<'static>, EncodeError>
where
    RId: Copy + Eq + Hash + PartialEq + fmt::Debug,
{
    let allocation = allocations
        .get_mut(&relay)
        .ok_or(EncodeError::NoAllocation)?;
    let payload = allocation
        .encode_to_vec(dest, contents, now)
        .ok_or(EncodeError::NoChannel)?;

    Ok(Transmit {
        src: None,
        dst: allocation.server(),
        payload: Cow::Owned(payload),
    })
}

#[derive(Debug)]
enum EncodeError {
    NoAllocation,
    NoChannel,
}

fn add_local_candidate_to_all<TId, RId>(
    candidate: Candidate,
    connections: &mut Connections<TId, RId>,
    pending_events: &mut VecDeque<Event<TId>>,
) where
    TId: Copy + fmt::Display,
{
    let initial_connections = connections
        .initial
        .iter_mut()
        .map(|(id, c)| (*id, &mut c.agent));
    let established_connections = connections
        .established
        .iter_mut()
        .map(|(id, c)| (*id, &mut c.agent));

    for (id, agent) in initial_connections.chain(established_connections) {
        let _span = info_span!("connection", %id).entered();

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
        pending_events.push_back(Event::NewIceCandidate {
            connection: id,
            candidate: candidate.to_sdp_string(),
        })
    }
}

fn remove_local_candidate<TId>(
    id: TId,
    agent: &mut IceAgent,
    candidate: &Candidate,
    pending_events: &mut VecDeque<Event<TId>>,
) where
    TId: fmt::Display,
{
    let was_present = agent.invalidate_candidate(candidate);

    if was_present {
        pending_events.push_back(Event::InvalidateIceCandidate {
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

#[derive(Debug, PartialEq, Clone)]
pub enum Event<TId> {
    /// We created a new candidate for this connection and ask to signal it to the remote party.
    ///
    /// Candidates are in SDP format although this may change and should be considered an implementation detail of the application.
    NewIceCandidate {
        connection: TId,
        candidate: String,
    },

    /// We invalidated a candidate for this connection and ask to signal that to the remote party.
    ///
    /// Candidates are in SDP format although this may change and should be considered an implementation detail of the application.
    InvalidateIceCandidate {
        connection: TId,
        candidate: String,
    },

    ConnectionEstablished(TId),

    /// We failed to establish a connection.
    ///
    /// All state associated with the connection has been cleared.
    ConnectionFailed(TId),
}

#[derive(Clone, Debug)]
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

struct Connection<RId> {
    agent: IceAgent,

    tunnel: Tunn,
    remote_pub_key: PublicKey,
    next_timer_update: Instant,

    state: ConnectionState<RId>,

    stats: ConnectionStats,
    intent_sent_at: Instant,
    signalling_completed_at: Instant,

    buffer: Box<[u8; MAX_UDP_SIZE]>,
}

enum ConnectionState<RId> {
    /// We are still running ICE to figure out, which socket to use to send data.
    Connecting {
        /// Socket addresses from which we might receive data (even before we are connected).
        possible_sockets: HashSet<SocketAddr>,
        /// Packets emitted by wireguard whilst are still running ICE.
        ///
        /// This can happen if the remote's WG session initiation arrives at our socket before we nominate it.
        /// A session initiation requires a response that we must not drop, otherwise the connection setup experiences unnecessary delays.
        buffered: RingBuffer<Vec<u8>>,
    },
    /// A socket has been nominated.
    Connected {
        /// Our nominated socket.
        peer_socket: PeerSocket<RId>,
        /// Other addresses that we might see traffic from (e.g. STUN messages during roaming).
        possible_sockets: HashSet<SocketAddr>,
    },
    /// The connection failed in an unrecoverable way and will be GC'd.
    Failed,
}

impl<RId> ConnectionState<RId> {
    fn add_possible_socket(&mut self, socket: SocketAddr) {
        let possible_sockets = match self {
            ConnectionState::Connecting {
                possible_sockets, ..
            } => possible_sockets,
            ConnectionState::Connected {
                possible_sockets, ..
            } => possible_sockets,
            ConnectionState::Failed => return,
        };

        possible_sockets.insert(socket);
    }
}

/// The socket of the peer we are connected to.
#[derive(Debug, PartialEq, Clone, Copy)]
enum PeerSocket<RId> {
    Direct {
        source: SocketAddr,
        dest: SocketAddr,
    },
    Relay {
        relay: RId,
        dest: SocketAddr,
    },
}

impl<RId> Connection<RId>
where
    RId: PartialEq + Eq + Hash + fmt::Debug + Copy,
{
    /// Checks if we want to accept a packet from a certain address.
    ///
    /// Whilst we establish connections, we may see traffic from a certain address, prior to the negotiation being fully complete.
    /// We already want to accept that traffic and not throw it away.
    #[must_use]
    fn accepts(&self, addr: &SocketAddr) -> bool {
        match &self.state {
            ConnectionState::Connecting {
                possible_sockets, ..
            } => possible_sockets.contains(addr),
            ConnectionState::Connected {
                peer_socket,
                possible_sockets,
            } => {
                let from_nominated = match peer_socket {
                    PeerSocket::Direct { dest, .. } => dest == addr,
                    PeerSocket::Relay { dest, .. } => dest == addr,
                };

                from_nominated || possible_sockets.contains(addr)
            }
            ConnectionState::Failed => false,
        }
    }

    fn wg_handshake_complete(&self) -> bool {
        self.tunnel.time_since_last_handshake().is_some()
    }

    fn duration_since_intent(&self, now: Instant) -> Duration {
        now.duration_since(self.intent_sent_at)
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
        allocations: &mut HashMap<RId, Allocation>,
        transmits: &mut VecDeque<Transmit<'static>>,
        pending_events: &mut VecDeque<Event<TId>>,
    ) where
        TId: fmt::Display + Copy,
        RId: Copy + fmt::Display,
    {
        self.agent.handle_timeout(now);

        if self
            .candidate_timeout()
            .is_some_and(|timeout| now >= timeout)
        {
            tracing::info!("Connection failed (no candidates received)");
            self.state = ConnectionState::Failed;
            return;
        }

        // TODO: `boringtun` is impure because it calls `Instant::now`.

        if now >= self.next_timer_update {
            self.next_timer_update = now + Duration::from_secs(1);

            // Don't update wireguard timers until we are connected.
            let Some(peer_socket) = self.socket() else {
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
                    self.state = ConnectionState::Failed;
                }
                TunnResult::Err(e) => {
                    tracing::warn!(?e);
                }
                TunnResult::WriteToNetwork(b) => {
                    transmits.extend(make_owned_transmit(peer_socket, b, allocations, now));
                }
                TunnResult::WriteToTunnelV4(..) | TunnResult::WriteToTunnelV6(..) => {
                    panic!("Unexpected result from update_timers")
                }
            };
        }

        while let Some(event) = self.agent.poll_event() {
            match event {
                IceAgentEvent::DiscoveredRecv { source, .. } => {
                    self.state.add_possible_socket(source);
                }
                IceAgentEvent::IceConnectionStateChange(IceConnectionState::Disconnected) => {
                    tracing::info!("Connection failed (ICE timeout)");
                    self.state = ConnectionState::Failed;
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

                    let old = match mem::replace(&mut self.state, ConnectionState::Failed) {
                        ConnectionState::Connecting {
                            possible_sockets,
                            buffered,
                        } => {
                            transmits.extend(buffered.into_iter().flat_map(|packet| {
                                make_owned_transmit(remote_socket, &packet, allocations, now)
                            }));
                            self.state = ConnectionState::Connected {
                                peer_socket: remote_socket,
                                possible_sockets,
                            };

                            None
                        }
                        ConnectionState::Connected {
                            peer_socket,
                            possible_sockets,
                        } if peer_socket == remote_socket => {
                            self.state = ConnectionState::Connected {
                                peer_socket,
                                possible_sockets,
                            };

                            continue; // If we re-nominate the same socket, don't just continue. TODO: Should this be fixed upstream?
                        }
                        ConnectionState::Connected {
                            peer_socket,
                            possible_sockets,
                        } => {
                            self.state = ConnectionState::Connected {
                                peer_socket: remote_socket,
                                possible_sockets,
                            };

                            Some(peer_socket)
                        }
                        ConnectionState::Failed => continue, // Failed connections are cleaned up, don't bother handling events.
                    };

                    tracing::info!(?old, new = ?remote_socket, duration_since_intent = ?self.duration_since_intent(now), "Updating remote socket");

                    self.invalidate_candiates(id, allocations, pending_events);
                    self.force_handshake(allocations, transmits, now);
                }
                IceAgentEvent::IceRestart(_) | IceAgentEvent::IceConnectionStateChange(_) => {}
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
                dst: allocation.server(),
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
        packet: &[u8],
        buffer: &'b mut [u8],
        allocations: &mut HashMap<RId, Allocation>,
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
                let ipv4_packet =
                    MutableIpv4Packet::new(packet).expect("boringtun verifies validity");
                debug_assert_eq!(ipv4_packet.get_source(), ip);

                ControlFlow::Continue(ipv4_packet.into())
            }
            TunnResult::WriteToTunnelV6(packet, ip) => {
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
                match &mut self.state {
                    ConnectionState::Connecting { buffered, .. } => {
                        tracing::debug!("No socket has been nominated yet, buffering WG packet");

                        buffered.push(bytes.to_owned());

                        while let TunnResult::WriteToNetwork(packet) =
                            self.tunnel.decapsulate(None, &[], self.buffer.as_mut())
                        {
                            buffered.push(packet.to_owned());
                        }
                    }
                    ConnectionState::Connected { peer_socket, .. } => {
                        transmits.extend(make_owned_transmit(
                            *peer_socket,
                            bytes,
                            allocations,
                            now,
                        ));

                        while let TunnResult::WriteToNetwork(packet) =
                            self.tunnel.decapsulate(None, &[], self.buffer.as_mut())
                        {
                            transmits.extend(make_owned_transmit(
                                *peer_socket,
                                packet,
                                allocations,
                                now,
                            ));
                        }
                    }
                    ConnectionState::Failed => {}
                }

                ControlFlow::Break(Ok(()))
            }
        }
    }

    fn force_handshake(
        &mut self,
        allocations: &mut HashMap<RId, Allocation>,
        transmits: &mut VecDeque<Transmit<'static>>,
        now: Instant,
    ) where
        RId: Copy,
    {
        /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
        ///
        /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
        const MAX_SCRATCH_SPACE: usize = 148;

        let mut buf = [0u8; MAX_SCRATCH_SPACE];

        let TunnResult::WriteToNetwork(bytes) =
            self.tunnel.format_handshake_initiation(&mut buf, false)
        else {
            return;
        };

        let socket = self
            .socket()
            .expect("cannot force handshake while not connected");

        transmits.extend(make_owned_transmit(socket, bytes, allocations, now));
    }

    /// Invalidates all local candidates with a lower or equal priority compared to the nominated one.
    ///
    /// Each time we nominate a candidate pair, we don't really want to keep all the others active because it creates a lot of noise.
    /// At the same time, we want to retain trickle ICE and allow the ICE agent to find a _better_ pair, hence we invalidate by priority.
    #[tracing::instrument(level = "debug", skip_all, fields(nominated_prio))]
    fn invalidate_candiates<TId>(
        &mut self,
        id: TId,
        allocations: &HashMap<RId, Allocation>,
        pending_events: &mut VecDeque<Event<TId>>,
    ) where
        TId: Copy + fmt::Display,
    {
        let Some(socket) = self.socket() else {
            return;
        };

        let socket = match socket {
            PeerSocket::Direct { source, .. } => source,
            PeerSocket::Relay { relay, .. } => match allocations.get(&relay) {
                Some(r) => r.server(),
                None => return,
            },
        };

        let Some(nominated) = self.local_candidate(socket).cloned() else {
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
            remove_local_candidate(id, &mut self.agent, &candidate, pending_events)
        }
    }

    fn local_candidate(&self, source: SocketAddr) -> Option<&Candidate> {
        self.agent
            .local_candidates()
            .iter()
            .filter(|c| !c.discarded())
            .find(|c| c.addr() == source)
    }

    fn socket(&self) -> Option<PeerSocket<RId>> {
        match self.state {
            ConnectionState::Connected { peer_socket, .. } => Some(peer_socket),
            ConnectionState::Connecting { .. } | ConnectionState::Failed => None,
        }
    }

    fn is_failed(&self) -> bool {
        matches!(self.state, ConnectionState::Failed)
    }
}

#[must_use]
fn make_owned_transmit<RId>(
    socket: PeerSocket<RId>,
    message: &[u8],
    allocations: &mut HashMap<RId, Allocation>,
    now: Instant,
) -> Option<Transmit<'static>>
where
    RId: Copy + Eq + Hash + PartialEq + fmt::Debug,
{
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
