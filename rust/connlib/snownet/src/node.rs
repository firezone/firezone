use crate::allocation::{Allocation, CandidateEvent, RelaySocket, Socket};
use crate::candidate_set::CandidateSet;
use crate::index::IndexLfsr;
use crate::ringbuffer::RingBuffer;
use crate::stats::{ConnectionStats, NodeStats};
use crate::utils::earliest;
use boringtun::noise::errors::WireGuardError;
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::PublicKey;
use boringtun::{noise::rate_limiter::RateLimiter, x25519::StaticSecret};
use core::fmt;
use firezone_logging::std_dyn_err;
use hex_display::HexDisplayExt;
use ip_packet::{
    ConvertibleIpv4Packet, ConvertibleIpv6Packet, IpPacket, IpPacketBuf, MAX_DATAGRAM_PAYLOAD,
};
use rand::rngs::StdRng;
use rand::seq::IteratorRandom;
use rand::{random, Rng, SeedableRng};
use secrecy::{ExposeSecret, Secret};
use sha2::Digest;
use std::borrow::Cow;
use std::collections::btree_map::Entry;
use std::collections::{BTreeMap, BTreeSet};
use std::hash::Hash;
use std::mem;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};
use std::{collections::VecDeque, net::SocketAddr, sync::Arc};
use str0m::ice::{IceAgent, IceAgentEvent, IceCreds, StunMessage, StunPacket};
use str0m::net::Protocol;
use str0m::{Candidate, CandidateKind, IceConnectionState};
use stun_codec::rfc5389::attributes::{Realm, Username};
use tracing::info_span;

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

/// How long we will at most wait for a candidate from the remote.
const CANDIDATE_TIMEOUT: Duration = Duration::from_secs(10);

/// How long we will at most wait for an [`Answer`] from the remote.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);

/// Manages a set of wireguard connections for a server.
pub type ServerNode<TId, RId> = Node<Server, TId, RId>;
/// Manages a set of wireguard connections for a client.
pub type ClientNode<TId, RId> = Node<Client, TId, RId>;

#[non_exhaustive]
pub struct Server {}

#[non_exhaustive]
pub struct Client {}

trait Mode {
    fn new() -> Self;
    fn is_client(&self) -> bool;
}

impl Mode for Server {
    fn is_client(&self) -> bool {
        false
    }

    fn new() -> Self {
        Self {}
    }
}

impl Mode for Client {
    fn is_client(&self) -> bool {
        true
    }

    fn new() -> Self {
        Self {}
    }
}

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
    public_key: PublicKey,
    session_id: SessionId,

    index: IndexLfsr,
    rate_limiter: Arc<RateLimiter>,
    /// Host and server-reflexive candidates that are shared between all connections.
    shared_candidates: CandidateSet,
    buffered_transmits: VecDeque<Transmit<'static>>,

    next_rate_limiter_reset: Option<Instant>,

    allocations: BTreeMap<RId, Allocation>,

    connections: Connections<TId, RId>,
    pending_events: VecDeque<Event<TId>>,

    stats: NodeStats,

    mode: T,
    rng: StdRng,
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

#[expect(private_bounds, reason = "We don't want `Mode` to be public API")]
impl<T, TId, RId> Node<T, TId, RId>
where
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
    T: Mode,
{
    pub fn new(seed: [u8; 32]) -> Self {
        let mut rng = StdRng::from_seed(seed);
        let private_key = StaticSecret::random_from_rng(&mut rng);
        let public_key = &(&private_key).into();

        Self {
            rng,
            session_id: SessionId::new(*public_key),
            private_key,
            public_key: *public_key,
            mode: T::new(),
            index: IndexLfsr::default(),
            rate_limiter: Arc::new(RateLimiter::new(public_key, HANDSHAKE_RATE_LIMIT)),
            shared_candidates: Default::default(),
            buffered_transmits: VecDeque::default(),
            next_rate_limiter_reset: None,
            pending_events: VecDeque::default(),
            allocations: Default::default(),
            connections: Default::default(),
            stats: Default::default(),
        }
    }

    /// Resets this [`Node`].
    ///
    /// # Implementation note
    ///
    /// This also clears all [`Allocation`]s.
    /// An [`Allocation`] on a TURN server is identified by the client's 3-tuple (IP, port, protocol).
    /// Thus, clearing the [`Allocation`]'s state here without closing it means we won't be able to make a new one until:
    /// - it times out
    /// - we change our IP or port
    ///
    /// `snownet` cannot control which IP / port we are binding to, thus upper layers MUST ensure that a new IP / port is allocated after calling [`Node::reset`].
    pub fn reset(&mut self) {
        self.allocations.clear();

        self.buffered_transmits.clear();

        self.pending_events.clear();

        let closed_connections = self
            .connections
            .iter_ids()
            .map(Event::ConnectionClosed)
            .collect::<Vec<_>>();
        let num_connections = closed_connections.len();

        self.pending_events.extend(closed_connections);

        self.shared_candidates.clear();
        self.connections.clear();
        self.buffered_transmits.clear();

        self.private_key = StaticSecret::random_from_rng(&mut self.rng);
        self.public_key = (&self.private_key).into();
        self.rate_limiter = Arc::new(RateLimiter::new(&self.public_key, HANDSHAKE_RATE_LIMIT));
        self.session_id = SessionId::new(self.public_key);

        tracing::debug!(%num_connections, "Closed all connections as part of reconnecting");
    }

    pub fn num_connections(&self) -> usize {
        self.connections.len()
    }

    /// Upserts a connection to the given remote.
    ///
    /// If we already have a connection with the same ICE credentials, this does nothing.
    /// Otherwise, the existing connection is discarded and a new one will be created.
    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn upsert_connection(
        &mut self,
        cid: TId,
        remote: PublicKey,
        session_key: Secret<[u8; 32]>,
        local_creds: Credentials,
        remote_creds: Credentials,
        now: Instant,
    ) {
        let local_creds = local_creds.into();
        let remote_creds = remote_creds.into();

        if self.connections.initial.contains_key(&cid) {
            debug_assert!(false, "The new `upsert_connection` API is incompatible with the previous `new_connection` API");
            return;
        }

        if self
            .connections
            .get_established_mut(&cid)
            .is_some_and(|c| c.agent.local_credentials() == &local_creds)
        {
            tracing::debug!("Already got a connection");
            return;
        }

        let selected_relay = self.sample_relay();

        let mut agent = new_agent();
        agent.set_controlling(self.mode.is_client());
        agent.set_local_credentials(local_creds);
        agent.set_remote_credentials(remote_creds);

        self.seed_agent_with_local_candidates(cid, selected_relay, &mut agent);

        let connection = self.init_connection(
            cid,
            agent,
            remote,
            *session_key.expose_secret(),
            selected_relay,
            now,
            now,
        );

        let existing = self.connections.established.insert(cid, connection);

        if existing.is_some() {
            tracing::info!("Replaced existing connection");
        } else {
            tracing::info!("Created new connection");
        }
    }

    pub fn public_key(&self) -> PublicKey {
        self.public_key
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

    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn add_remote_candidate(&mut self, cid: TId, candidate: String, now: Instant) {
        let candidate = match Candidate::from_sdp_string(&candidate) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!(error = std_dyn_err(&e), "Failed to parse candidate");
                return;
            }
        };

        let Some((agent, relay)) = self.connections.connecting_agent_mut(cid) else {
            tracing::debug!("Unknown connection or socket has already been nominated");
            return;
        };

        agent.add_remote_candidate(candidate.clone());

        match candidate.kind() {
            CandidateKind::Host => {
                // Binding a TURN channel for host candidates does not make sense.
                // They are only useful to circumvent restrictive NATs in which case we are either talking to another relay candidate or a server-reflexive address.
                return;
            }
            CandidateKind::Relayed
            | CandidateKind::ServerReflexive
            | CandidateKind::PeerReflexive => {}
        }

        let Some(rid) = relay else {
            tracing::debug!("No relay selected for connection");
            return;
        };

        let Some(allocation) = self.allocations.get_mut(&rid) else {
            tracing::debug!(%rid, "Unknown relay");
            return;
        };

        allocation.bind_channel(candidate.addr(), now);
    }

    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn remove_remote_candidate(&mut self, cid: TId, candidate: String, now: Instant) {
        let candidate = match Candidate::from_sdp_string(&candidate) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!(error = std_dyn_err(&e), "Failed to parse candidate");
                return;
            }
        };

        if let Some(agent) = self.connections.agent_mut(cid) {
            agent.invalidate_candidate(&candidate);
            agent.handle_timeout(now); // We may have invalidated the last candidate, ensure we check our nomination state.
        }
    }

    /// Decapsulate an incoming packet.
    ///
    /// # Returns
    ///
    /// - `Ok(None)` if the packet was handled internally, for example, a response from a TURN server.
    /// - `Ok(Some)` if the packet was an encrypted wireguard packet from a peer.
    ///   The `Option` contains the connection on which the packet was decrypted.
    pub fn decapsulate(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Result<Option<(TId, IpPacket)>, Error> {
        self.add_local_as_host_candidate(local)?;

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

        let (id, packet) = match self.connections_try_handle(from, packet, now) {
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
    pub fn encapsulate(
        &mut self,
        connection: TId,
        packet: IpPacket,
        now: Instant,
        buffer: &mut EncryptBuffer,
    ) -> Result<Option<EncryptedPacket>, Error> {
        let conn = self
            .connections
            .get_established_mut(&connection)
            .ok_or(Error::NotConnected)?;

        // Encode the packet with an offset of 4 bytes, in case we need to wrap it in a channel-data message.
        let Some(packet_len) = conn
            .encapsulate(packet.packet(), &mut buffer.inner[4..], now)?
            .map(|p| p.len())
        // Mapping to len() here terminate the mutable borrow of buffer, allowing re-borrowing further down.
        else {
            return Ok(None);
        };

        let packet_start = 4;
        let packet_end = 4 + packet_len;

        let socket = match &mut conn.state {
            ConnectionState::Connecting { buffered, .. } => {
                buffered.push(buffer.inner[packet_start..packet_end].to_vec());
                let num_buffered = buffered.len();

                let _guard = conn.span.enter();

                tracing::debug!(%num_buffered, "ICE is still in progress, buffering WG handshake");

                return Ok(None);
            }
            ConnectionState::Connected { peer_socket, .. } => peer_socket,
            ConnectionState::Idle { peer_socket } => peer_socket,
            ConnectionState::Failed => return Err(Error::NotConnected),
        };

        match *socket {
            PeerSocket::Direct {
                dest: remote,
                source,
            } => Ok(Some(EncryptedPacket {
                src: Some(source),
                dst: remote,
                packet_start,
                packet_len,
            })),
            PeerSocket::Relay { relay, dest: peer } => {
                let Some(allocation) = self.allocations.get(&relay) else {
                    tracing::warn!(%relay, "No allocation");
                    return Ok(None);
                };
                let packet = &mut buffer.inner[..packet_end];

                let Some(enc_packet) = allocation.encode_to_encrypted_packet(peer, packet, now)
                else {
                    tracing::warn!(%peer, "No channel");
                    return Ok(None);
                };

                Ok(Some(enc_packet))
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

        for (_, c) in self.connections.iter_initial_mut() {
            connection_timeout = earliest(connection_timeout, c.poll_timeout());
        }
        for (_, c) in self.connections.iter_established_mut() {
            connection_timeout = earliest(connection_timeout, c.poll_timeout());
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
        for allocation in self.allocations.values_mut() {
            allocation.handle_timeout(now);
        }

        self.allocations_drain_events();

        for (id, connection) in self.connections.iter_established_mut() {
            connection.handle_timeout(id, now, &mut self.allocations, &mut self.buffered_transmits);
        }

        for (id, connection) in self.connections.initial.iter_mut() {
            connection.handle_timeout(id, now);
        }

        if self.connections.all_idle() {
            // If all connections are idle, there is no point in resetting the rate limiter.
            self.next_rate_limiter_reset = None;
        } else {
            let next_reset = *self.next_rate_limiter_reset.get_or_insert(now);

            if now >= next_reset {
                self.rate_limiter.reset_count();
                self.next_rate_limiter_reset = Some(now + Duration::from_secs(1));
            }
        }

        self.allocations
            .retain(|rid, allocation| match allocation.can_be_freed() {
                Some(e) => {
                    tracing::warn!(%rid, "Disconnecting from relay; {e}");

                    false
                }
                None => true,
            });
        self.connections
            .check_relays_available(&self.allocations, &mut self.rng);
        self.connections.gc(&mut self.pending_events);
    }

    /// Returns buffered data that needs to be sent on the socket.
    #[must_use]
    pub fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        let allocation_transmits = &mut self
            .allocations
            .values_mut()
            .flat_map(Allocation::poll_transmit);

        if let Some(transmit) = allocation_transmits.next() {
            self.stats.stun_bytes_to_relays += transmit.payload.len();
            tracing::trace!(?transmit);

            return Some(transmit);
        }

        let transmit = self.buffered_transmits.pop_front()?;

        tracing::trace!(?transmit);

        Some(transmit)
    }

    pub fn update_relays(
        &mut self,
        to_remove: BTreeSet<RId>,
        to_add: &BTreeSet<(RId, RelaySocket, String, String, String)>,
        now: Instant,
    ) {
        // First, invalidate all candidates from relays that we should stop using.
        for rid in &to_remove {
            let Some(allocation) = self.allocations.remove(rid) else {
                tracing::debug!(%rid, "Cannot delete unknown allocation");

                continue;
            };

            invalidate_allocation_candidates(
                &mut self.connections,
                &allocation,
                &mut self.pending_events,
            );

            tracing::info!(%rid, address = ?allocation.server(), "Removed TURN server");
        }

        // Second, insert new relays.
        for (rid, server, username, password, realm) in to_add {
            let Ok(username) = Username::new(username.to_owned()) else {
                tracing::debug!(%username, "Invalid TURN username");
                continue;
            };
            let Ok(realm) = Realm::new(realm.to_owned()) else {
                tracing::debug!(%realm, "Invalid TURN realm");
                continue;
            };

            match self.allocations.entry(*rid) {
                Entry::Vacant(v) => {
                    v.insert(Allocation::new(
                        *server,
                        username,
                        password.clone(),
                        realm,
                        now,
                        self.session_id.clone(),
                    ));

                    tracing::info!(%rid, address = ?server, "Added new TURN server");
                }
                Entry::Occupied(mut o) => {
                    let allocation = o.get();

                    if allocation.matches_credentials(&username, password)
                        && allocation.matches_socket(server)
                    {
                        tracing::info!(%rid, address = ?server, "Skipping known TURN server");
                        continue;
                    }

                    invalidate_allocation_candidates(
                        &mut self.connections,
                        allocation,
                        &mut self.pending_events,
                    );

                    o.insert(Allocation::new(
                        *server,
                        username,
                        password.clone(),
                        realm,
                        now,
                        self.session_id.clone(),
                    ));

                    tracing::info!(%rid, address = ?server, "Replaced TURN server");
                }
            }
        }

        let newly_added_relays = to_add
            .iter()
            .map(|(id, _, _, _, _)| *id)
            .collect::<BTreeSet<_>>();

        // Third, check if other relays are still present.
        for (_, previous_allocation) in self
            .allocations
            .iter_mut()
            .filter(|(id, _)| !newly_added_relays.contains(id))
        {
            previous_allocation.refresh(now);
        }
    }

    #[must_use]
    #[expect(clippy::too_many_arguments)]
    fn init_connection(
        &mut self,
        cid: TId,
        mut agent: IceAgent,
        remote: PublicKey,
        key: [u8; 32],
        relay: Option<RId>,
        intent_sent_at: Instant,
        now: Instant,
    ) -> Connection<RId> {
        agent.handle_timeout(now);

        if self.allocations.is_empty() {
            tracing::warn!("No TURN servers connected; connection may fail to establish");
        }

        Connection {
            agent,
            tunnel: Tunn::new(
                self.private_key.clone(),
                remote,
                Some(key),
                Some(25), // 25 is the default of the kernel implementation.
                self.index.next(),
                Some(self.rate_limiter.clone()),
            ),
            wg_timer: DEFAULT_WG_TIMER,
            next_wg_timer_update: now,
            stats: Default::default(),
            buffer: vec![0; ip_packet::MAX_DATAGRAM_PAYLOAD],
            intent_sent_at,
            signalling_completed_at: now,
            remote_pub_key: remote,
            state: ConnectionState::Connecting {
                relay,
                buffered: RingBuffer::new(10),
            },
            possible_sockets: BTreeSet::default(),
            span: info_span!(parent: tracing::Span::none(), "connection", %cid),
        }
    }

    /// Attempt to add the `local` address as a host candidate.
    ///
    /// Receiving traffic on a certain interface means we at least have a connection to a relay via this interface.
    /// Thus, it is also a viable interface to attempt a connection to a gateway.
    fn add_local_as_host_candidate(&mut self, local: SocketAddr) -> Result<(), Error> {
        let host_candidate = Candidate::host(local, Protocol::Udp)?;

        if self.shared_candidates.insert(host_candidate.clone()) {
            return Ok(());
        }

        for (cid, agent, _span) in self.connections.agents_mut() {
            add_local_candidate(cid, agent, host_candidate.clone(), &mut self.pending_events);
        }

        Ok(())
    }

    /// Tries to handle the packet using one of our [`Allocation`]s.
    ///
    /// This function is in the hot-path of packet processing and thus must be as efficient as possible.
    /// Even look-ups in [`BTreeMap`]s and linear searches across small lists are expensive at this point.
    /// Thus, we use the first byte of the message as a heuristic for whether we should attempt to handle it here.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2> for details on de-multiplexing.
    ///
    /// This heuristic might fail because we are also handling wireguard packets.
    /// Those are fully encrypted and thus any byte pattern may appear at the front of the packet.
    /// We can detect this by further checking the origin of the packet.
    #[must_use]
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
                let Some(allocation) = self
                    .allocations
                    .values_mut()
                    .find(|a| a.server().matches(from))
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
                let Some(allocation) = self
                    .allocations
                    .values_mut()
                    .find(|a| a.server().matches(from))
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

        for (_, agent, _span) in self.connections.agents_mut() {
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
    fn connections_try_handle(
        &mut self,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> ControlFlow<Result<(), Error>, (TId, IpPacket)> {
        for (cid, conn) in self.connections.iter_established_mut() {
            if !conn.accepts(&from) {
                continue;
            }

            let handshake_complete_before_decapsulate = conn.wg_handshake_complete();

            let control_flow = conn.decapsulate(
                packet,
                &mut self.allocations,
                &mut self.buffered_transmits,
                now,
            );

            let handshake_complete_after_decapsulate = conn.wg_handshake_complete();

            // I can't think of a better way to detect this ...
            if !handshake_complete_before_decapsulate && handshake_complete_after_decapsulate {
                tracing::info!(%cid, duration_since_intent = ?conn.duration_since_intent(now), "Completed wireguard handshake");

                self.pending_events
                    .push_back(Event::ConnectionEstablished(cid))
            }

            return match control_flow {
                ControlFlow::Continue(c) => ControlFlow::Continue((cid, c)),
                ControlFlow::Break(b) => ControlFlow::Break(b),
            };
        }

        ControlFlow::Break(Err(Error::UnhandledPacket {
            num_tunnels: self.connections.iter_established_mut().count(),
        }))
    }

    fn allocations_drain_events(&mut self) {
        let allocation_events = self.allocations.iter_mut().flat_map(|(rid, allocation)| {
            std::iter::from_fn(|| allocation.poll_event()).map(|e| (*rid, e))
        });

        for (rid, event) in allocation_events {
            tracing::trace!(%rid, ?event);

            match event {
                CandidateEvent::New(candidate)
                    if candidate.kind() == CandidateKind::ServerReflexive =>
                {
                    self.shared_candidates.insert(candidate);
                }
                CandidateEvent::New(candidate) => {
                    for (cid, agent, _span) in self.connections.connecting_agents_by_relay_mut(rid)
                    {
                        add_local_candidate(cid, agent, candidate.clone(), &mut self.pending_events)
                    }
                }
                CandidateEvent::Invalid(candidate) => {
                    for (cid, agent, _span) in self.connections.agents_mut() {
                        remove_local_candidate(cid, agent, &candidate, &mut self.pending_events);
                    }
                }
            }
        }
    }

    /// Sample a relay to use for a new connection.
    fn sample_relay(&mut self) -> Option<RId> {
        let rid = self.allocations.keys().copied().choose(&mut self.rng)?;

        tracing::debug!(%rid, "Sampled relay");

        Some(rid)
    }
}

impl<TId, RId> Node<Client, TId, RId>
where
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
{
    /// Create a new connection indexed by the given ID.
    ///
    /// Out of all configured STUN and TURN servers, the connection will only use the ones provided here.
    /// The returned [`Offer`] must be passed to the remote via a signalling channel.
    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    #[must_use]
    #[deprecated]
    #[expect(deprecated)]
    pub fn new_connection(&mut self, cid: TId, intent_sent_at: Instant, now: Instant) -> Offer {
        if self.connections.initial.remove(&cid).is_some() {
            tracing::info!("Replacing existing initial connection");
        };

        if self.connections.established.remove(&cid).is_some() {
            tracing::info!("Replacing existing established connection");
        };

        let mut agent = new_agent();
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
            created_at: now,
            intent_sent_at,
            relay: self.sample_relay(),
            is_failed: false,
            span: info_span!("connection", %cid),
        };
        let duration_since_intent = initial_connection.duration_since_intent(now);

        let existing = self.connections.initial.insert(cid, initial_connection);
        debug_assert!(existing.is_none());

        tracing::info!(?duration_since_intent, "Establishing new connection");

        params
    }

    /// Whether we have sent an [`Offer`] for this connection and are currently expecting an [`Answer`].
    pub fn is_expecting_answer(&self, id: TId) -> bool {
        self.connections.initial.contains_key(&id)
    }

    /// Accept an [`Answer`] from the remote for a connection previously created via [`Node::new_connection`].
    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    #[deprecated]
    #[expect(deprecated)]
    pub fn accept_answer(&mut self, cid: TId, remote: PublicKey, answer: Answer, now: Instant) {
        let Some(initial) = self.connections.initial.remove(&cid) else {
            tracing::debug!("No initial connection state, ignoring answer"); // This can happen if the connection setup timed out.
            return;
        };

        let mut agent = initial.agent;
        agent.set_remote_credentials(IceCreds {
            ufrag: answer.credentials.username,
            pass: answer.credentials.password,
        });

        let selected_relay = initial.relay;

        self.seed_agent_with_local_candidates(cid, selected_relay, &mut agent);

        let connection = self.init_connection(
            cid,
            agent,
            remote,
            *initial.session_key.expose_secret(),
            selected_relay,
            initial.intent_sent_at,
            now,
        );
        let duration_since_intent = connection.duration_since_intent(now);

        let existing = self.connections.established.insert(cid, connection);

        tracing::info!(?duration_since_intent, remote = %hex::encode(remote.as_bytes()), "Signalling protocol completed");

        debug_assert!(existing.is_none());
    }
}

impl<TId, RId> Node<Server, TId, RId>
where
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
{
    /// Accept a new connection indexed by the given ID.
    ///
    /// Out of all configured STUN and TURN servers, the connection will only use the ones provided here.
    /// The returned [`Answer`] must be passed to the remote via a signalling channel.
    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    #[must_use]
    #[deprecated]
    #[expect(deprecated)]
    pub fn accept_connection(
        &mut self,
        cid: TId,
        offer: Offer,
        remote: PublicKey,
        now: Instant,
    ) -> Answer {
        debug_assert!(
            !self.connections.initial.contains_key(&cid),
            "server to not use `initial_connections`"
        );

        if self.connections.established.remove(&cid).is_some() {
            tracing::info!("Replacing existing established connection");
        };

        let mut agent = new_agent();
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

        let selected_relay = self.sample_relay();
        self.seed_agent_with_local_candidates(cid, selected_relay, &mut agent);

        let connection = self.init_connection(
            cid,
            agent,
            remote,
            *offer.session_key.expose_secret(),
            selected_relay,
            now, // Technically, this isn't fully correct because gateways don't send intents so we just use the current time.
            now,
        );
        let existing = self.connections.established.insert(cid, connection);

        debug_assert!(existing.is_none());

        tracing::info!("Created new connection");

        answer
    }
}

impl<T, TId, RId> Node<T, TId, RId>
where
    TId: Eq + Hash + Copy + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
{
    fn seed_agent_with_local_candidates(
        &mut self,
        connection: TId,
        selected_relay: Option<RId>,
        agent: &mut IceAgent,
    ) {
        for candidate in self.shared_candidates.iter().cloned() {
            add_local_candidate(connection, agent, candidate, &mut self.pending_events);
        }

        let Some(selected_relay) = selected_relay else {
            tracing::debug!("Skipping seeding of relay candidates: No relay selected");
            return;
        };

        let Some(allocation) = self.allocations.get(&selected_relay) else {
            tracing::debug!(%selected_relay, "Cannot seed relay candidates: Unknown relay");
            return;
        };

        for candidate in allocation.current_relay_candidates() {
            add_local_candidate(connection, agent, candidate, &mut self.pending_events);
        }
    }
}

struct Connections<TId, RId> {
    initial: BTreeMap<TId, InitialConnection<RId>>,
    established: BTreeMap<TId, Connection<RId>>,
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
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
{
    fn gc(&mut self, events: &mut VecDeque<Event<TId>>) {
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

    fn check_relays_available(
        &mut self,
        allocations: &BTreeMap<RId, Allocation>,
        rng: &mut impl Rng,
    ) {
        // For initial connections, we can just update the relay to be used.
        for (_, c) in self.iter_initial_mut() {
            if c.relay.is_some_and(|r| allocations.contains_key(&r)) {
                continue;
            }

            let _guard = c.span.enter();

            let Some(new_rid) = allocations.keys().copied().choose(rng) else {
                continue;
            };

            tracing::info!(old_rid = ?c.relay, %new_rid, "Updating relay");
            c.relay = Some(new_rid);
        }

        // For established connections, we check if we are currently using the relay.
        for (_, c) in self.iter_established_mut() {
            let _guard = c.span.enter();

            use ConnectionState::*;
            let peer_socket = match &mut c.state {
                Connected { peer_socket, .. } | Idle { peer_socket } => peer_socket,
                Failed => continue,
                Connecting {
                    relay: maybe_relay, ..
                } => {
                    let Some(relay) = maybe_relay else {
                        continue;
                    };

                    if allocations.contains_key(relay) {
                        continue;
                    }

                    tracing::debug!("Selected relay disconnected during ICE; connection may fail");
                    *maybe_relay = None;
                    continue;
                }
            };

            let relay = match peer_socket {
                PeerSocket::Direct { .. } => continue, // Don't care if relay of direct connection disappears, we weren't using it anyway.
                PeerSocket::Relay { relay, .. } => relay,
            };

            if allocations.contains_key(relay) {
                continue; // Our relay is still there, no problems.
            }

            tracing::info!("Connection failed (relay disconnected)");
            c.state = ConnectionState::Failed;
        }
    }

    fn stats(&self) -> impl Iterator<Item = (TId, ConnectionStats)> + '_ {
        self.established.iter().map(move |(id, c)| (*id, c.stats))
    }

    fn agent_mut(&mut self, id: TId) -> Option<&mut IceAgent> {
        let maybe_initial_connection = self.initial.get_mut(&id).map(|i| &mut i.agent);
        let maybe_established_connection = self.established.get_mut(&id).map(|c| &mut c.agent);

        maybe_initial_connection.or(maybe_established_connection)
    }

    fn connecting_agent_mut(&mut self, id: TId) -> Option<(&mut IceAgent, Option<RId>)> {
        let maybe_initial_connection = self.initial.get_mut(&id).map(|i| (&mut i.agent, i.relay));
        let maybe_pending_connection = self.established.get_mut(&id).and_then(|c| match c.state {
            ConnectionState::Connecting { relay, .. } => Some((&mut c.agent, relay)),
            ConnectionState::Failed
            | ConnectionState::Idle { .. }
            | ConnectionState::Connected { .. } => None,
        });

        maybe_initial_connection.or(maybe_pending_connection)
    }

    fn connecting_agents_by_relay_mut(
        &mut self,
        id: RId,
    ) -> impl Iterator<Item = (TId, &mut IceAgent, tracing::span::Entered<'_>)> + '_ {
        let initial_connections = self.initial.iter_mut().filter_map(move |(cid, i)| {
            (i.relay? == id).then_some((*cid, &mut i.agent, i.span.enter()))
        });
        let pending_connections = self.established.iter_mut().filter_map(move |(cid, c)| {
            use ConnectionState::*;

            match c.state {
                Connecting {
                    relay: Some(relay), ..
                } if relay == id => Some((*cid, &mut c.agent, c.span.enter())),
                Failed | Idle { .. } | Connecting { .. } | Connected { .. } => None,
            }
        });

        initial_connections.chain(pending_connections)
    }

    fn agents_mut(
        &mut self,
    ) -> impl Iterator<Item = (TId, &mut IceAgent, tracing::span::Entered<'_>)> {
        let initial_agents = self
            .initial
            .iter_mut()
            .map(|(id, c)| (*id, &mut c.agent, c.span.enter()));
        let negotiated_agents = self
            .established
            .iter_mut()
            .map(|(id, c)| (*id, &mut c.agent, c.span.enter()));

        initial_agents.chain(negotiated_agents)
    }

    fn get_established_mut(&mut self, id: &TId) -> Option<&mut Connection<RId>> {
        self.established.get_mut(id)
    }

    fn iter_initial_mut(&mut self) -> impl Iterator<Item = (TId, &mut InitialConnection<RId>)> {
        self.initial.iter_mut().map(|(id, conn)| (*id, conn))
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

    fn clear(&mut self) {
        self.initial.clear();
        self.established.clear();
    }

    fn iter_ids(&self) -> impl Iterator<Item = TId> + '_ {
        self.initial.keys().chain(self.established.keys()).copied()
    }

    fn all_idle(&self) -> bool {
        self.established.values().all(|c| c.is_idle())
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
    allocations: &mut BTreeMap<RId, Allocation>,
    now: Instant,
) -> Result<Transmit<'static>, EncodeError>
where
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug,
{
    let allocation = allocations
        .get_mut(&relay)
        .ok_or(EncodeError::NoAllocation)?;
    let transmit = allocation
        .encode_to_owned_transmit(dest, contents, now)
        .ok_or(EncodeError::NoChannel)?;

    Ok(transmit)
}

#[derive(Debug)]
enum EncodeError {
    NoAllocation,
    NoChannel,
}

fn add_local_candidate<TId>(
    id: TId,
    agent: &mut IceAgent,
    candidate: Candidate,
    pending_events: &mut VecDeque<Event<TId>>,
) where
    TId: fmt::Display,
{
    // srflx candidates don't need to be added to the local agent because we always send from the `base` anyway.
    if candidate.kind() == CandidateKind::ServerReflexive {
        pending_events.push_back(Event::NewIceCandidate {
            connection: id,
            candidate: candidate.to_sdp_string(),
        });
        return;
    }

    let is_new = agent.add_local_candidate(candidate.clone());

    if is_new {
        pending_events.push_back(Event::NewIceCandidate {
            connection: id,
            candidate: candidate.to_sdp_string(),
        })
    }
}

fn invalidate_allocation_candidates<TId, RId>(
    connections: &mut Connections<TId, RId>,
    allocation: &Allocation,
    pending_events: &mut VecDeque<Event<TId>>,
) where
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
{
    for (cid, agent, _guard) in connections.agents_mut() {
        for candidate in allocation.current_relay_candidates() {
            remove_local_candidate(cid, agent, &candidate, pending_events);
        }
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
    if candidate.kind() == CandidateKind::ServerReflexive {
        pending_events.push_back(Event::NewIceCandidate {
            connection: id,
            candidate: candidate.to_sdp_string(),
        });
        return;
    }

    let was_present = agent.invalidate_candidate(candidate);

    if was_present {
        pending_events.push_back(Event::InvalidateIceCandidate {
            connection: id,
            candidate: candidate.to_sdp_string(),
        })
    }
}

#[deprecated]
pub struct Offer {
    /// The Wireguard session key for a connection.
    pub session_key: Secret<[u8; 32]>,
    pub credentials: Credentials,
}

#[deprecated]
pub struct Answer {
    pub credentials: Credentials,
}

pub struct Credentials {
    /// The ICE username (ufrag).
    pub username: String,
    /// The ICE password.
    pub password: String,
}

#[doc(hidden)] // Not public API.
impl From<Credentials> for str0m::IceCreds {
    fn from(value: Credentials) -> Self {
        str0m::IceCreds {
            ufrag: value.username,
            pass: value.password,
        }
    }
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

    /// We closed a connection (e.g. due to inactivity, roaming, etc).
    ConnectionClosed(TId),
}

pub struct EncryptBuffer {
    inner: Vec<u8>,
}

impl EncryptBuffer {
    pub fn new() -> Self {
        Self {
            inner: vec![0u8; MAX_DATAGRAM_PAYLOAD], // TODO: Stack-allocate this?
        }
    }
}

impl Default for EncryptBuffer {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Copy)]
pub struct EncryptedPacket {
    pub(crate) src: Option<SocketAddr>,
    pub(crate) dst: SocketAddr,
    pub(crate) packet_start: usize,
    pub(crate) packet_len: usize,
}

impl EncryptedPacket {
    pub fn to_transmit(self, buf: &EncryptBuffer) -> Transmit<'_> {
        Transmit {
            src: self.src,
            dst: self.dst,
            payload: Cow::Borrowed(
                &buf.inner[self.packet_start..(self.packet_start + self.packet_len)],
            ),
        }
    }

    pub fn dst(&self) -> SocketAddr {
        self.dst
    }
}

#[derive(Clone, PartialEq, PartialOrd, Eq, Ord)]
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

impl<'a> fmt::Debug for Transmit<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Transmit")
            .field("src", &self.src)
            .field("dst", &self.dst)
            .field("len", &self.payload.len())
            .finish()
    }
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

struct InitialConnection<RId> {
    agent: IceAgent,
    session_key: Secret<[u8; 32]>,

    /// The fallback relay we sampled for this potential connection.
    ///
    /// `None` if we don't have any relays available.
    relay: Option<RId>,

    created_at: Instant,
    intent_sent_at: Instant,

    is_failed: bool,

    span: tracing::Span,
}

impl<RId> InitialConnection<RId> {
    #[tracing::instrument(level = "debug", skip_all, fields(%cid))]
    fn handle_timeout<TId>(&mut self, cid: TId, now: Instant)
    where
        TId: fmt::Display,
    {
        self.agent.handle_timeout(now);

        if now >= self.no_answer_received_timeout() {
            tracing::info!("Connection setup timed out (no answer received)");
            self.is_failed = true;
        }
    }

    fn poll_timeout(&mut self) -> Option<Instant> {
        earliest(
            self.agent.poll_timeout(),
            Some(self.no_answer_received_timeout()),
        )
    }

    fn no_answer_received_timeout(&self) -> Instant {
        self.created_at + HANDSHAKE_TIMEOUT
    }

    fn duration_since_intent(&self, now: Instant) -> Duration {
        now.duration_since(self.intent_sent_at)
    }
}

struct Connection<RId> {
    agent: IceAgent,

    tunnel: Tunn,
    remote_pub_key: PublicKey,
    /// At which interval we update the [`Tunn`]s timers.
    wg_timer: Duration,
    /// When to next update the [`Tunn`]'s timers.
    next_wg_timer_update: Instant,

    state: ConnectionState<RId>,

    /// Socket addresses from which we might receive data (even before we are connected).
    possible_sockets: BTreeSet<SocketAddr>,

    stats: ConnectionStats,
    intent_sent_at: Instant,
    signalling_completed_at: Instant,

    buffer: Vec<u8>,

    span: tracing::Span,
}

enum ConnectionState<RId> {
    /// We are still running ICE to figure out, which socket to use to send data.
    Connecting {
        /// The relay we have selected for this connection.
        ///
        /// `None` if we didn't have any relays available.
        relay: Option<RId>,

        /// Packets emitted by wireguard whilst are still running ICE.
        ///
        /// This can happen if the remote's WG session initiation arrives at our socket before we nominate it.
        /// A session initiation requires a response that we must not drop, otherwise the connection setup experiences unnecessary delays.
        ///
        /// It can also happen if we attempt to encapsulate a packet prior to the WireGuard handshake which triggers the creation of a WireGuard handshake initiation packet.
        buffered: RingBuffer<Vec<u8>>,
    },
    /// A socket has been nominated.
    Connected {
        /// Our nominated socket.
        peer_socket: PeerSocket<RId>,

        last_outgoing: Instant,
        last_incoming: Instant,
    },
    /// We haven't seen application packets in a while.
    Idle {
        /// Our nominated socket.
        peer_socket: PeerSocket<RId>,
    },
    /// The connection failed in an unrecoverable way and will be GC'd.
    Failed,
}

impl<RId> ConnectionState<RId>
where
    RId: Copy,
{
    fn poll_timeout(&self) -> Option<Instant> {
        match self {
            ConnectionState::Connected {
                last_incoming,
                last_outgoing,
                ..
            } => Some(idle_at(*last_incoming, *last_outgoing)),
            ConnectionState::Connecting { .. }
            | ConnectionState::Idle { .. }
            | ConnectionState::Failed => None,
        }
    }

    fn handle_timeout(&mut self, agent: &mut IceAgent, wg_timer: &mut Duration, now: Instant) {
        let Self::Connected {
            last_outgoing,
            last_incoming,
            peer_socket,
        } = self
        else {
            return;
        };

        if idle_at(*last_incoming, *last_outgoing) > now {
            return;
        }

        let peer_socket = *peer_socket;

        self.transition_to_idle(peer_socket, agent, wg_timer);
    }

    fn on_outgoing(&mut self, agent: &mut IceAgent, wg_timer: &mut Duration, now: Instant) {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_outgoing, .. } => {
                *last_outgoing = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(peer_socket, agent, wg_timer, now);
    }

    fn on_incoming(&mut self, agent: &mut IceAgent, wg_timer: &mut Duration, now: Instant) {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_incoming, .. } => {
                *last_incoming = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(peer_socket, agent, wg_timer, now);
    }

    fn transition_to_idle(
        &mut self,
        peer_socket: PeerSocket<RId>,
        agent: &mut IceAgent,
        wg_timer: &mut Duration,
    ) {
        tracing::debug!("Connection is idle");
        *self = Self::Idle { peer_socket };
        apply_idle_stun_timings(agent);
        *wg_timer = IDLE_WG_TIMER;
    }

    fn transition_to_connected(
        &mut self,
        peer_socket: PeerSocket<RId>,
        agent: &mut IceAgent,
        wg_timer: &mut Duration,
        now: Instant,
    ) {
        tracing::debug!("Connection resumed");
        *self = Self::Connected {
            peer_socket,
            last_outgoing: now,
            last_incoming: now,
        };
        apply_default_stun_timings(agent);
        *wg_timer = DEFAULT_WG_TIMER;
    }
}

fn idle_at(last_incoming: Instant, last_outgoing: Instant) -> Instant {
    const MAX_IDLE: Duration = Duration::from_secs(10);

    last_incoming.max(last_outgoing) + MAX_IDLE
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
    RId: PartialEq + Eq + Hash + fmt::Debug + Copy + Ord,
{
    /// Checks if we want to accept a packet from a certain address.
    ///
    /// Whilst we establish connections, we may see traffic from a certain address, prior to the negotiation being fully complete.
    /// We already want to accept that traffic and not throw it away.
    #[must_use]
    fn accepts(&self, addr: &SocketAddr) -> bool {
        let from_nominated = match &self.state {
            ConnectionState::Idle { peer_socket }
            | ConnectionState::Connected { peer_socket, .. } => match peer_socket {
                PeerSocket::Direct { dest, .. } => dest == addr,
                PeerSocket::Relay { dest, .. } => dest == addr,
            },
            ConnectionState::Failed | ConnectionState::Connecting { .. } => false,
        };

        from_nominated || self.possible_sockets.contains(addr)
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
        let next_wg_timer = Some(self.next_wg_timer_update);
        let candidate_timeout = self.candidate_timeout();
        let idle_timeout = self.state.poll_timeout();

        earliest(
            idle_timeout,
            earliest(agent_timeout, earliest(next_wg_timer, candidate_timeout)),
        )
    }

    fn candidate_timeout(&self) -> Option<Instant> {
        if !self.agent.remote_candidates().is_empty() {
            return None;
        }

        Some(self.signalling_completed_at + CANDIDATE_TIMEOUT)
    }

    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    fn handle_timeout<TId>(
        &mut self,
        cid: TId,
        now: Instant,
        allocations: &mut BTreeMap<RId, Allocation>,
        transmits: &mut VecDeque<Transmit<'static>>,
    ) where
        TId: Copy + Ord + fmt::Display,
        RId: Copy + Ord + fmt::Display,
    {
        self.agent.handle_timeout(now);
        self.state
            .handle_timeout(&mut self.agent, &mut self.wg_timer, now);

        if self
            .candidate_timeout()
            .is_some_and(|timeout| now >= timeout)
        {
            tracing::info!("Connection failed (no candidates received)");
            self.state = ConnectionState::Failed;
            return;
        }

        // TODO: `boringtun` is impure because it calls `Instant::now`.

        if now >= self.next_wg_timer_update {
            self.next_wg_timer_update = now + self.wg_timer;

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
                    self.possible_sockets.insert(source);
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
                    let remote_socket = allocations
                        .iter()
                        .find_map(|(relay, allocation)| {
                            allocation.has_socket(source).then_some(*relay)
                        })
                        .map(|relay| PeerSocket::Relay {
                            relay,
                            dest: destination,
                        })
                        .unwrap_or(PeerSocket::Direct {
                            source,
                            dest: destination,
                        });

                    let old = match mem::replace(&mut self.state, ConnectionState::Failed) {
                        ConnectionState::Connecting { buffered, .. } => {
                            let num_buffered = buffered.len();

                            tracing::debug!(%num_buffered, "Flushing packets buffered during ICE");

                            transmits.extend(buffered.into_iter().flat_map(|packet| {
                                make_owned_transmit(remote_socket, &packet, allocations, now)
                            }));
                            self.state = ConnectionState::Connected {
                                peer_socket: remote_socket,
                                last_incoming: now,
                                last_outgoing: now,
                            };

                            None
                        }
                        ConnectionState::Connected {
                            peer_socket,
                            last_incoming,
                            last_outgoing,
                        } if peer_socket == remote_socket => {
                            self.state = ConnectionState::Connected {
                                peer_socket,
                                last_incoming,
                                last_outgoing,
                            };

                            continue; // If we re-nominate the same socket, don't just continue. TODO: Should this be fixed upstream?
                        }
                        ConnectionState::Connected {
                            peer_socket,
                            last_incoming,
                            last_outgoing,
                        } => {
                            self.state = ConnectionState::Connected {
                                peer_socket: remote_socket,
                                last_incoming,
                                last_outgoing,
                            };

                            Some(peer_socket)
                        }
                        ConnectionState::Idle { peer_socket } => {
                            self.state = ConnectionState::Idle { peer_socket };

                            Some(peer_socket)
                        }
                        ConnectionState::Failed => continue, // Failed connections are cleaned up, don't bother handling events.
                    };

                    tracing::info!(?old, new = ?remote_socket, duration_since_intent = ?self.duration_since_intent(now), "Updating remote socket");

                    if self.agent.controlling() {
                        self.force_handshake(allocations, transmits, now);
                    }
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
            let Some(channel_data) = allocation.encode_to_owned_transmit(dst, &packet, now) else {
                // Unlikely edge-case, drop the packet and continue.
                tracing::trace!(%relay, peer = %dst, "Dropping packet because allocation does not offer a channel to peer");
                continue;
            };

            self.stats.stun_bytes_to_peer_relayed += channel_data.payload.len();

            transmits.push_back(channel_data);
        }
    }

    fn encapsulate<'b>(
        &mut self,
        packet: &[u8],
        buffer: &'b mut [u8],
        now: Instant,
    ) -> Result<Option<&'b [u8]>, Error> {
        let _guard = self.span.enter();

        let len = match self.tunnel.encapsulate(packet, buffer) {
            TunnResult::Done => return Ok(None),
            TunnResult::Err(e) => return Err(Error::Encapsulate(e)),
            TunnResult::WriteToNetwork(packet) => packet.len(),
            TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                unreachable!("never returned from encapsulate")
            }
        };

        self.state
            .on_outgoing(&mut self.agent, &mut self.wg_timer, now);

        Ok(Some(&buffer[..len]))
    }

    fn decapsulate(
        &mut self,
        packet: &[u8],
        allocations: &mut BTreeMap<RId, Allocation>,
        transmits: &mut VecDeque<Transmit<'static>>,
        now: Instant,
    ) -> ControlFlow<Result<(), Error>, IpPacket> {
        let _guard = self.span.enter();
        let mut ip_packet = IpPacketBuf::new();

        let control_flow = match self.tunnel.decapsulate(None, packet, ip_packet.buf()) {
            TunnResult::Done => ControlFlow::Break(Ok(())),
            TunnResult::Err(e) => ControlFlow::Break(Err(Error::Decapsulate(e))),

            // For WriteToTunnel{V4,V6}, boringtun returns the source IP of the packet that was tunneled to us.
            // I am guessing this was done for convenience reasons.
            // In our API, we parse the packets directly as an IpPacket.
            // Thus, the caller can query whatever data they'd like, not just the source IP so we don't return it in addition.
            TunnResult::WriteToTunnelV4(packet, ip) => {
                let packet_len = packet.len();
                let ipv4_packet = ConvertibleIpv4Packet::new(ip_packet, packet_len)
                    .expect("boringtun verifies validity");
                debug_assert_eq!(ipv4_packet.get_source(), ip);

                ControlFlow::Continue(ipv4_packet.into())
            }
            TunnResult::WriteToTunnelV6(packet, ip) => {
                // For ipv4 we need to use buffer to create the ip packet because we need the extra 20 bytes at the beginning
                // for ipv6 we just need this to convince the borrow-checker that `packet`'s lifetime isn't `'b`, otherwise it's taken
                // as `'b` for all branches.
                let packet_len = packet.len();
                let ipv6_packet = ConvertibleIpv6Packet::new(ip_packet, packet_len)
                    .expect("boringtun verifies validity");
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
                    ConnectionState::Connected { peer_socket, .. }
                    | ConnectionState::Idle { peer_socket } => {
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
        };

        if control_flow.is_continue() {
            self.state
                .on_incoming(&mut self.agent, &mut self.wg_timer, now);
        }

        control_flow
    }

    fn force_handshake(
        &mut self,
        allocations: &mut BTreeMap<RId, Allocation>,
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

    fn socket(&self) -> Option<PeerSocket<RId>> {
        match self.state {
            ConnectionState::Connected { peer_socket, .. }
            | ConnectionState::Idle { peer_socket } => Some(peer_socket),
            ConnectionState::Connecting { .. } | ConnectionState::Failed => None,
        }
    }

    fn is_failed(&self) -> bool {
        matches!(self.state, ConnectionState::Failed)
    }

    fn is_idle(&self) -> bool {
        matches!(self.state, ConnectionState::Idle { .. })
    }
}

#[must_use]
fn make_owned_transmit<RId>(
    socket: PeerSocket<RId>,
    message: &[u8],
    allocations: &mut BTreeMap<RId, Allocation>,
    now: Instant,
) -> Option<Transmit<'static>>
where
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug,
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

fn new_agent() -> IceAgent {
    let mut agent = IceAgent::new();
    agent.set_max_candidate_pairs(300);
    agent.set_timing_advance(Duration::ZERO);
    apply_default_stun_timings(&mut agent);

    agent
}

/// By default, we will update the internal timers of a WireGuard tunnel every second.
///
/// This allows [`boringtun`] to send keep-alive and re-key messages at the correct times.
const DEFAULT_WG_TIMER: Duration = Duration::from_secs(1);

/// When a connection is idle, the only thing that [`boringtun`] needs to do is send keep-alive messages.
///
/// Those happen at a rate of 25s.
/// By waking up less often, we can save some CPU power.
const IDLE_WG_TIMER: Duration = Duration::from_secs(30);

fn apply_default_stun_timings(agent: &mut IceAgent) {
    agent.set_max_stun_retransmits(8);
    agent.set_max_stun_rto(Duration::from_millis(1500));
    agent.set_initial_stun_rto(Duration::from_millis(250))
}

fn apply_idle_stun_timings(agent: &mut IceAgent) {
    agent.set_max_stun_retransmits(4);
    agent.set_max_stun_rto(Duration::from_secs(60));
    agent.set_initial_stun_rto(Duration::from_secs(60));
}

/// A session ID is constant for as long as a [`Node`] is operational.
#[derive(Debug, Default, Clone)]
pub(crate) struct SessionId([u8; 32]);

impl SessionId {
    /// Construct a new session ID by hashing the node's public key with a domain-separator.
    fn new(key: PublicKey) -> Self {
        Self(
            sha2::Sha256::new_with_prefix(b"SESSION-ID")
                .chain_update(key.as_bytes())
                .finalize()
                .into(),
        )
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:X}", &self.0.hex())
    }
}
