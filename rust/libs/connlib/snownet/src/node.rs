mod allocations;
mod connection_state;
mod connections;
mod inflight_stun_requests;
mod timeout_cache;

pub use connections::UnknownConnection;

use crate::agent::Agent;
use crate::allocation::{self, Allocation, RelaySocket, Socket};
use crate::buffer::{BufferProvider, Reservation, TransmitBuffer};
use crate::index::IndexLfsr;
use crate::node::allocations::Allocations;
use crate::node::connection_state::{ConnectionState, PeerSocket};
use crate::node::connections::Connections;
use crate::node::inflight_stun_requests::InflightStunRequests;
use crate::node::timeout_cache::TimeoutCache;
use crate::stats::{ConnectionStats, NodeStats};
use crate::utils::channel_data_packet_buffer;
use anyhow::{Context, Result, anyhow};
use boringtun::noise::errors::WireGuardError;
use boringtun::noise::{
    HandshakeResponse, Index, Packet, PacketCookieReply, PacketData, Tunn, TunnResult,
};
use boringtun::x25519::{self, PublicKey};
use boringtun::{noise::rate_limiter::RateLimiter, x25519::StaticSecret};
use bufferpool::{Buffer, BufferPool};
use core::fmt;
use ip_packet::{Ecn, IpPacket, IpPacketBuf};
use is::stun::{StunMessage, StunPacket};
use is::{Candidate, CandidateKind, IceConnectionState};
use is::{IceAgent, IceAgentEvent};
use itertools::Itertools;
use opentelemetry::metrics::Gauge;
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use ringbuffer::{AllocRingBuffer, RingBuffer};
use smallvec::SmallVec;
use std::collections::BTreeSet;
use std::hash::Hash;
use std::net::IpAddr;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};
use std::{collections::VecDeque, net::SocketAddr, sync::Arc};
use std::{iter, mem};
use stun_codec::rfc5389::attributes::{Realm, Username};

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

/// How long we will at most wait for a candidate from the remote.
const CANDIDATE_TIMEOUT: Duration = Duration::from_secs(10);

/// Grace-period for when we will act on an ICE disconnect.
const DISCONNECT_TIMEOUT: Duration = Duration::from_secs(2);

/// For how long we will at most try to re-key a WireGuard tunnel.
const WG_REKEY_ATTEMPT_TIME: Duration = Duration::from_secs(20);

/// How long we wait between [`Event::NoRelays`] emissions.
///
/// Guards against a request-response loop with the portal in case allocations fail shortly after each provisioning (e.g. when UDP traffic to relays is blocked).
const NO_RELAYS_EVENT_COOLDOWN: Duration = Duration::from_secs(60);

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
/// A [`Node`] is generic over two things:
/// - `TId`: The type to use for uniquely identifying connections.
/// - `RId`: The type to use for uniquely identifying relays.
///
/// We favor these generic parameters over having our own IDs to avoid mapping back and forth in upper layers.
pub struct Node<TId, RId> {
    private_key: StaticSecret,
    public_key: PublicKey,

    index: IndexLfsr,
    rate_limiter: Arc<RateLimiter>,

    buffered_transmits: TransmitBuffer,

    next_rate_limiter_reset: Option<Instant>,

    /// Whether to emit [`Event::NoRelays`] once we run out of allocations.
    ///
    /// Armed every time we are provided with relays, disarmed when we emit the event.
    /// Thus, we ask at most once per provided set of relays.
    request_relays_when_empty: bool,
    /// Do not emit [`Event::NoRelays`] before this instant.
    next_no_relays_event: Option<Instant>,

    allocations: Allocations<RId>,

    connections: Connections<TId, RId>,
    inflight_stun_requests: InflightStunRequests<TId>,

    pending_events: VecDeque<Event<TId>>,

    stats: NodeStats,
    buffer_pool: BufferPool<Vec<u8>>,

    connection_count: Gauge<u64>,

    rng: StdRng,

    /// The number of seconds since the UNIX epoch.
    unix_ts: Duration,
    /// The [`Instant`] at the time we read the UNIX epoch above.
    unix_now: Instant,
}

#[derive(thiserror::Error, Debug)]
#[error("No TURN servers available")]
pub struct NoTurnServers {}

/// The connection exists but is not yet ready to send application packets because ICE is
/// still in progress (no socket has been nominated yet).
///
/// Callers should buffer the packet and retry once the connection is established.
#[derive(thiserror::Error, Debug)]
#[error("Connection is still establishing")]
pub struct StillConnecting;

#[derive(Debug, Clone, Copy)]
pub struct IceConfig {
    pub(crate) max_retrans: usize,
    pub(crate) max_rto: Duration,
    pub(crate) initial_rto: Duration,
}

impl IceConfig {
    pub fn server_default() -> Self {
        Self {
            max_retrans: 45,
            max_rto: Duration::from_millis(15_000),
            initial_rto: Duration::from_millis(250),
        }
    }

    pub fn server_idle() -> Self {
        IceConfig {
            max_retrans: 40,
            max_rto: Duration::from_secs(25),
            initial_rto: Duration::from_secs(25),
        }
    }

    pub fn client_default() -> Self {
        Self {
            max_retrans: 12,
            max_rto: Duration::from_millis(1500),
            initial_rto: Duration::from_millis(250),
        }
    }

    pub fn client_idle() -> Self {
        Self {
            max_retrans: 4,
            max_rto: Duration::from_secs(25),
            initial_rto: Duration::from_secs(25),
        }
    }

    #[cfg(test)]
    fn apply(&self, agent: &mut IceAgent) {
        agent.set_max_stun_retransmits(self.max_retrans);
        agent.set_max_stun_rto(self.max_rto);
        agent.set_initial_stun_rto(self.initial_rto)
    }
}

#[derive(Debug, Clone, Copy)]
pub enum IceRole {
    Controlling,
    Controlled,
}

impl<TId, RId> Node<TId, RId>
where
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
{
    pub fn new(seed: [u8; 32], now: Instant, unix_ts: Duration) -> Self {
        let mut rng = StdRng::from_seed(seed);
        let private_key = StaticSecret::random_from_rng(&mut rng);
        let public_key = &(&private_key).into();
        let index = IndexLfsr::new(&mut rng);
        let allocations = Allocations::new(&mut rng);

        Self {
            rng,
            private_key,
            public_key: *public_key,
            index,
            rate_limiter: Arc::new(RateLimiter::new_at(public_key, HANDSHAKE_RATE_LIMIT, now)),
            buffered_transmits: TransmitBuffer::default(),
            next_rate_limiter_reset: None,
            request_relays_when_empty: false,
            next_no_relays_event: None,
            pending_events: VecDeque::default(),
            allocations,
            inflight_stun_requests: Default::default(),
            connections: Default::default(),
            stats: Default::default(),
            buffer_pool: BufferPool::new(ip_packet::MAX_FZ_PAYLOAD, "snownet"),
            connection_count: otel_instruments::connection_count(),
            unix_now: now,
            unix_ts,
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
    pub fn reset(&mut self, now: Instant) {
        self.allocations.clear();
        self.buffered_transmits.clear();
        self.pending_events.clear();
        self.inflight_stun_requests.clear();

        // Upper layers MUST re-provision relays after a reset (e.g. by reconnecting to the portal); no need to ask for them.
        self.request_relays_when_empty = false;

        if self.connections.all_iceless() {
            let num_iceless = self.connections.reset_for_roam(now);
            tracing::debug!(
                %num_iceless,
                "Soft-reset iceless connections (path-agent reset, key kept)"
            );
            return;
        }

        let closed_connections = self
            .connections
            .iter_ids()
            .map(Event::ConnectionClosed)
            .collect::<Vec<_>>();
        let num_connections = closed_connections.len();

        self.pending_events.extend(closed_connections);

        self.connections.clear();

        self.private_key = StaticSecret::random_from_rng(&mut self.rng);
        self.public_key = (&self.private_key).into();
        self.rate_limiter = Arc::new(RateLimiter::new_at(
            &self.public_key,
            HANDSHAKE_RATE_LIMIT,
            now,
        ));

        tracing::debug!(%num_connections, "Closed all connections as part of reconnecting");
    }

    pub fn num_connections(&self) -> usize {
        self.connections.len()
    }

    /// Upserts a connection to the given remote.
    ///
    /// If we already have a connection with the same parameters, this does nothing.
    /// Otherwise, the existing connection is discarded and a new one will be created.
    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn upsert_connection(
        &mut self,
        cid: TId,
        remote: PublicKey,
        preshared_key: x25519::StaticSecret,
        local_creds: Credentials,
        remote_creds: Credentials,
        ice_role: IceRole,
        default_ice_config: IceConfig,
        idle_ice_config: IceConfig,
        use_iceless: bool,
        now: Instant,
    ) -> Result<(), NoTurnServers> {
        let local_creds = local_creds.into();
        let remote_creds = remote_creds.into();

        // Reuse only if every parameter that feeds boringtun's
        // session matches, including the agent mode — a flag flip
        // forces a replace.
        if let Ok(c) = self.connections.get_mut(&cid, now)
            && c.agent.matches_existing_connection(
                &local_creds,
                &remote_creds,
                ice_role,
                use_iceless,
            )
            && c.tunnel.remote_static_public() == remote
            && c.tunnel.preshared_key().as_bytes() == preshared_key.as_bytes()
        {
            tracing::info!(local = ?local_creds, "Reusing existing connection");

            c.state
                .on_upsert(cid, &mut c.agent, c.default_ice_config, now);

            let iceless = c.agent.is_iceless();

            // Take all current candidates.
            let current_candidates = c.agent.local_candidates().collect::<SmallVec<[_; 16]>>();

            // Re-seed connection with all candidates.
            let new_candidates =
                seed_agent_with_local_candidates(c.relay.id, &mut c.agent, &self.allocations);

            // Tell the remote about all of them.
            self.pending_events.extend(
                std::iter::empty()
                    .chain(current_candidates)
                    .chain(new_candidates)
                    .map(|candidate| new_ice_candidate_event(cid, candidate, iceless)),
            );

            // Initiate a new WG session.
            //
            // We can have up to 8 concurrent WireGuard sessions in boringtun before the oldest one gets overwritten.
            // Also, whilst we are handshaking a new session, we won't send another handshake.
            // Thus, even rapid successive connection upserts should be handled just fine.
            if c.agent.send_wg_handshake_after_nomination() {
                c.initiate_wg_session(&mut self.allocations, &mut self.buffered_transmits, now);
            }

            return Ok(());
        }

        let selected_relay = self.sample_relay()?;

        let existing = self.connections.remove_established(&cid, now);
        let index = self.index.next();

        if let Some(existing) = existing {
            let current_local = existing.agent.local_ufrag();
            tracing::info!(?current_local, new_local = ?local_creds, remote = ?remote_creds, current_index = %existing.index, new_index = %index, "Replacing existing connection");
        } else {
            tracing::info!(local = ?local_creds, remote = ?remote_creds, %index, "Creating new connection");
        }

        let mut agent = if use_iceless {
            tracing::debug!(%cid, "Using iceless path-agent for connection");
            Agent::path()
        } else {
            tracing::debug!(%cid, "Using ICE agent for connection");
            Agent::ice(new_agent(ice_role))
        };

        agent.apply_ice_config(default_ice_config);
        agent.set_local_credentials(local_creds);
        agent.set_remote_credentials(remote_creds);

        self.pending_events.extend(
            self.allocations
                .candidates_for_relay(&selected_relay)
                .filter_map(|candidate| {
                    let candidate = agent.add_local_candidate(candidate)?;
                    let event = new_ice_candidate_event(cid, candidate, use_iceless);

                    Some(event)
                }),
        );

        let mut connection = self.init_connection(
            cid,
            agent,
            remote,
            preshared_key,
            selected_relay,
            index,
            default_ice_config,
            idle_ice_config,
            now,
            now,
        );

        // Only Controlling fans out the init, so we don't burn
        // bandwidth and TURN channel bindings on a duplicate from
        // each side.
        if connection.agent.is_iceless() && matches!(ice_role, IceRole::Controlling) {
            connection.initiate_wg_session_for_path(now);
        }

        self.connections.insert_established(cid, index, connection);

        Ok(())
    }

    /// Removes a connection by just clearing its local memory.
    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn remove_connection(&mut self, cid: TId, reason: impl fmt::Display, now: Instant) {
        let existing = self.connections.remove_established(&cid, now);

        if existing.is_none() {
            return;
        }

        tracing::info!("Connection removed ({reason})");
    }

    /// Closes a connection to the provided peer.
    ///
    /// If we are connected, sends the provided "goodbye" packet before discarding the connection.
    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn close_connection(&mut self, cid: TId, goodbye: IpPacket, now: Instant) {
        let Some(mut connection) = self.connections.remove_established(&cid, now) else {
            tracing::debug!("Cannot close unknown connection");

            return;
        };

        let peer_socket = match connection.state {
            ConnectionState::Connected { peer_socket, .. }
            | ConnectionState::Idle { peer_socket } => peer_socket,
            ConnectionState::Connecting { .. } => {
                tracing::info!("Connection closed during ICE");
                return;
            }
            ConnectionState::Failed => return,
        };

        self.pending_events.push_back(Event::ConnectionClosed(cid));

        match connection.encapsulate(
            cid,
            peer_socket,
            &goodbye,
            now,
            &mut self.allocations,
            &mut self.buffered_transmits,
        ) {
            Ok(Some(_)) => {
                tracing::info!("Connection closed proactively (sent goodbye)");
            }
            Ok(None) => {
                tracing::info!("Connection closed proactively (failed to send goodbye)");
            }
            Err(e) => {
                tracing::info!("Connection closed proactively (failed to send goodbye: {e:#})");
            }
        }
    }

    pub fn close_all(&mut self, goodbye: IpPacket, now: Instant) {
        for id in self.connections.iter_ids().collect::<Vec<_>>() {
            self.close_connection(id, goodbye.clone(), now);
        }
    }

    pub fn public_key(&self) -> PublicKey {
        self.public_key
    }

    pub fn connection_id(&self, key: PublicKey, now: Instant) -> Option<TId> {
        self.connections.iter_established().find_map(|(id, c)| {
            (c.remote_pub_key == key && c.tunnel.time_since_last_handshake_at(now).is_some())
                .then_some(id)
        })
    }

    pub fn stats(&self) -> (NodeStats, impl Iterator<Item = (TId, ConnectionStats)> + '_) {
        (self.stats, self.connections.stats())
    }

    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn add_remote_candidate(&mut self, cid: TId, candidate: String, now: Instant) {
        let Ok(c) = self.connections.get_mut(&cid, now) else {
            tracing::warn!(%candidate, "Received candidate for unknown connection");
            return;
        };

        let Some(candidate) = crate::candidate::decode(c.agent.is_iceless(), &candidate) else {
            return;
        };

        tracing::debug!(?candidate, "Received candidate from remote");

        c.add_remote_candidate(cid, candidate.clone(), now);

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

        let Some(allocation) = self.allocations.get_mut_by_id(&c.relay.id) else {
            tracing::debug!(rid = %c.relay.id, "Unknown relay");
            return;
        };

        allocation.bind_channel(candidate.addr(), now);
    }

    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn remove_remote_candidate(&mut self, cid: TId, candidate: String, now: Instant) {
        let Ok(c) = self.connections.get_mut(&cid, now) else {
            tracing::debug!(ignored_candidate = %candidate, "Unknown connection");
            return;
        };

        let Some(candidate) = crate::candidate::decode(c.agent.is_iceless(), &candidate) else {
            return;
        };

        tracing::debug!(?candidate, "Received invalidated candidate from remote");

        c.remove_remote_candidate(cid, candidate, now);
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
    ) -> Result<Option<(TId, IpPacket)>> {
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

        let (id, packet) = match self.connections_try_handle(from, destination, packet, now) {
            ControlFlow::Continue(c) => c,
            ControlFlow::Break(Ok(())) => return Ok(None),
            ControlFlow::Break(Err(e)) => return Err(e),
        };

        Ok(Some((id, packet)))
    }

    /// Encapsulate an outgoing IP packet, writing it directly into `provider` to avoid a copy.
    ///
    /// Wireguard is an IP tunnel, so we "enforce" that only IP packets are sent through it.
    /// We say "enforce" an [`IpPacket`] can be created from an (almost) arbitrary byte buffer at virtually no cost.
    /// Nevertheless, using [`IpPacket`] in our API has good documentation value.
    pub fn encapsulate(
        &mut self,
        cid: TId,
        packet: &IpPacket,
        now: Instant,
        provider: &mut impl BufferProvider,
    ) -> Result<Option<EncapsulateInfo>> {
        let conn = self.connections.get_mut(&cid, now)?;

        let socket = match &conn.state {
            ConnectionState::Connecting { .. } => {
                return Err(StillConnecting.into());
            }
            ConnectionState::Connected { peer_socket, .. } => *peer_socket,
            ConnectionState::Idle { peer_socket } => *peer_socket,
            ConnectionState::Failed => {
                return Err(anyhow!("Connection {cid} failed"));
            }
        };

        let info = conn
            .encapsulate(cid, socket, packet, now, &mut self.allocations, provider)
            .with_context(|| format!("cid={cid}"))?;

        Ok(info)
    }

    /// Returns a pending [`Event`] from the pool.
    #[must_use]
    pub fn poll_event(&mut self) -> Option<Event<TId>> {
        let event = self.pending_events.pop_front()?;

        if let Event::ConnectionClosed(id) | Event::ConnectionFailed(id) = &event {
            self.inflight_stun_requests.remove_by_conn_id(*id);
        }

        Some(event)
    }

    /// Returns, when [`Node::handle_timeout`] should be called next.
    ///
    /// This function only takes `&mut self` because it caches certain computations internally.
    /// The returned timestamp will **not** change unless other state is modified.
    #[must_use]
    pub fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            .chain(self.connections.poll_timeout())
            .chain(self.allocations.poll_timeout())
            .chain(
                self.next_rate_limiter_reset
                    .map(|instant| (instant, "rate limiter reset")),
            )
            .min_by_key(|(instant, _)| *instant)
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
        self.allocations.handle_timeout(now);

        self.allocations_drain_events(now);

        let mut connections_by_path = [0u64; PeerSocket::KINDS.len()];

        for (id, connection) in self.connections.iter_established_mut() {
            connection.handle_timeout(
                id,
                now,
                &mut self.allocations,
                &mut self.buffered_transmits,
                &mut self.pending_events,
                &mut self.inflight_stun_requests,
            );

            if let Some(peer_socket) = connection.state.peer_socket() {
                connections_by_path[peer_socket.kind_index()] += 1;
            }
        }

        // Report the current number of connections per network path. Every bucket is
        // emitted (including `0`) so that a path draining to zero is not stuck at its
        // last non-zero value.
        for (kind, count) in PeerSocket::KINDS.into_iter().zip(connections_by_path) {
            self.connection_count
                .record(count, &[telemetry::otel::attr::connection_socket(kind)]);
        }

        if self.connections.all_idle() {
            // If all connections are idle, there is no point in resetting the rate limiter.
            self.next_rate_limiter_reset = None;
        } else {
            let next_reset = *self.next_rate_limiter_reset.get_or_insert(now);

            if now >= next_reset {
                self.rate_limiter.reset_count_at(now);
                self.next_rate_limiter_reset = Some(now + Duration::from_secs(1));
            }
        }

        let removed_allocations = self.allocations.gc();

        self.connections.migrate_relays(
            removed_allocations,
            &mut self.allocations,
            &mut self.pending_events,
            now,
        );
        self.connections
            .handle_timeout(&mut self.pending_events, now);
        self.inflight_stun_requests.handle_timeout(now);

        if self.request_relays_when_empty
            && self.allocations.is_empty()
            && self.next_no_relays_event.is_none_or(|at| now >= at)
        {
            tracing::info!("No relays left; requesting a new set");

            self.pending_events.push_back(Event::NoRelays);
            self.request_relays_when_empty = false;
            self.next_no_relays_event = Some(now + NO_RELAYS_EVENT_COOLDOWN);
        }
    }

    /// Returns buffered data that needs to be sent on the socket.
    #[must_use]
    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        if let Some(transmit) = self.allocations.poll_transmit() {
            self.stats.stun_bytes_to_relays += transmit.payload.len();
            tracing::trace!(?transmit);

            return Some(transmit);
        }

        let transmit = self.buffered_transmits.poll_transmit()?;

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
            let Some(allocation) = self.allocations.remove_by_id(rid) else {
                tracing::debug!(%rid, "Cannot delete unknown allocation");

                continue;
            };

            invalidate_allocation_candidates(
                &mut self.connections,
                &allocation,
                &mut self.pending_events,
                now,
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

            match self
                .allocations
                .upsert(*rid, *server, username, password.clone(), realm, now)
            {
                allocations::UpsertResult::Added => {
                    tracing::info!(%rid, address = ?server, "Added new TURN server")
                }
                allocations::UpsertResult::Skipped => {
                    tracing::info!(%rid, address = ?server, "Skipping known TURN server")
                }
                allocations::UpsertResult::Replaced(previous) => {
                    invalidate_allocation_candidates(
                        &mut self.connections,
                        &previous,
                        &mut self.pending_events,
                        now,
                    );

                    tracing::info!(%rid, address = ?server, "Replaced TURN server")
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

        // Fourth, migrate existing connections away from removed relays.
        self.connections.migrate_relays(
            to_remove.into_iter(),
            &mut self.allocations,
            &mut self.pending_events,
            now,
        );

        if !self.allocations.is_empty() {
            self.request_relays_when_empty = true;
        }
    }

    #[must_use]
    fn init_connection(
        &mut self,
        cid: TId,
        mut agent: Agent,
        remote: PublicKey,
        key: x25519::StaticSecret,
        relay: RId,
        index: Index,
        default_ice_config: IceConfig,
        idle_ice_config: IceConfig,
        intent_sent_at: Instant,
        now: Instant,
    ) -> Connection<RId> {
        agent.handle_timeout(now);

        if self.allocations.is_empty() {
            tracing::warn!(%cid, "No TURN servers connected; connection may fail to establish");
        }

        let mut tunnel = Tunn::new_at(
            self.private_key.clone(),
            remote,
            Some(key),
            None,
            index,
            Some(self.rate_limiter.clone()),
            self.rng.next_u64(),
            now,
            self.unix_now,
            self.unix_ts,
        );
        // By default, boringtun has a rekey attempt time of 90(!) seconds.
        // In case of a state de-sync or other issues, this means we try for
        // 90s to make a handshake, all whilst our ICE layer thinks the connection
        // is working perfectly fine.
        // This results in a bad UX as the user has to essentially wait for 90s
        // before Firezone can fix the state and make a new connection.
        //
        // By aligning the rekey-attempt-time roughly with our ICE timeout, we ensure
        // that even if the hole-punch was successful, it will take at most 20s
        // until we have a WireGuard tunnel to send packets into.
        tunnel.set_rekey_attempt_time(WG_REKEY_ATTEMPT_TIME);

        Connection {
            agent,
            index,
            tunnel,
            next_wg_timer_update: now,
            stats: Default::default(),
            buffer: vec![0; ip_packet::MAX_FZ_PAYLOAD],
            intent_sent_at,
            remote_pub_key: remote,
            relay: SelectedRelay { id: relay },
            state: ConnectionState::Connecting {
                wg_buffer: AllocRingBuffer::new(128),
            },
            disconnected_at: None,
            buffer_pool: self.buffer_pool.clone(),
            last_proactive_handshake_sent_at: None,
            first_handshake_completed_at: None,
            default_ice_config,
            idle_ice_config,
            poll_timeout_cache: Default::default(),
            candidate_timeout: Some(now + CANDIDATE_TIMEOUT),
        }
    }

    /// Tries to handle the packet using one of our [`Allocation`]s.
    ///
    /// This function is in the hot-path of packet processing and thus must be as efficient as possible.
    /// Even look-ups in [`BTreeMap`](std::collections::BTreeMap)s and linear searches across small lists are expensive at this point.
    /// Thus, we use the first byte of the message as a heuristic for whether we should attempt to handle it here.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2> for details on de-multiplexing.
    ///
    /// This heuristic might fail because we are also handling wireguard packets.
    /// Those are fully encrypted and thus any byte pattern may appear at the front of the packet.
    /// We can detect this by further checking the origin of the packet.
    fn allocations_try_handle<'p>(
        &mut self,
        from: SocketAddr,
        local: SocketAddr,
        packet: &'p [u8],
        now: Instant,
    ) -> ControlFlow<(), (SocketAddr, &'p [u8], Option<Socket>)> {
        if from.port() != 3478 {
            // Relays always send & receive from port 3478.
            //
            // Some NATs may remap our p2p listening port (i.e. 52625 or another ephemeral one) to a port
            // in the non-ephemeral range. If this happens, there is a chance that a peer is sending
            // traffic originating from port 3478.
            //
            // The above check would wrongly classify a STUN request from such a peer as relay traffic and
            // fail to process it because we don't have an `Allocation` for the peer's IP.
            //
            // At the same time, we may still receive packets on port 3478 for an allocation that we have discarded.
            //
            // To correctly handle these packets, we need to handle them differently, depending on whether we
            // previously had an allocation on a certain relay:
            // 1. If we previously had an allocation, we need to stop processing the packet.
            // 2. If we don't recognize the IP, continue processing the packet (as it may be p2p traffic).
            return ControlFlow::Continue((from, packet, None));
        }

        match packet.first().copied() {
            // STUN method range
            Some(0..=3) => {
                let Ok(Ok(message)) = allocation::decode(packet) else {
                    // False-positive, continue processing packet elsewhere
                    return ControlFlow::Continue((from, packet, None));
                };

                let allocation = match self.allocations.get_mut_by_server(from) {
                    allocations::MutAllocationRef::Connected(_, allocation) => allocation,
                    allocations::MutAllocationRef::Disconnected => {
                        tracing::debug!(
                            %from,
                            packet = %hex::encode(packet),
                            "Packet was a STUN message but we are no longer connected to this relay"
                        );

                        return ControlFlow::Break(()); // Stop processing the packet.
                    }
                    allocations::MutAllocationRef::Unknown => {
                        return ControlFlow::Continue((from, packet, None));
                    }
                };

                if allocation.handle_input(from, local, message, now) {
                    // Successfully handled the packet
                    return ControlFlow::Break(());
                }

                tracing::debug!("Packet was a STUN message but not accepted");

                ControlFlow::Break(()) // Stop processing the packet.
            }
            // Channel data number range
            Some(64..=79) => {
                let Ok(cd) = crate::channel_data::decode(packet) else {
                    // False-positive, continue processing packet elsewhere
                    return ControlFlow::Continue((from, packet, None));
                };

                let allocation = match self.allocations.get_mut_by_server(from) {
                    allocations::MutAllocationRef::Connected(_, allocation) => allocation,
                    allocations::MutAllocationRef::Disconnected => {
                        tracing::debug!(
                            %from,
                            "Packet was a channel-data message but we are no longer connected to this relay"
                        );

                        return ControlFlow::Break(()); // Stop processing the packet.
                    }
                    allocations::MutAllocationRef::Unknown => {
                        return ControlFlow::Continue((from, packet, None));
                    }
                };

                let Some((from, packet, socket)) = allocation.decapsulate(from, cd, now) else {
                    tracing::debug!("Packet was a channel data message but not accepted"); // i.e. unbound channel etc

                    return ControlFlow::Break(()); // Stop processing the packet.
                };

                // Successfully handled the packet and decapsulated the channel data message.
                // Continue processing with the _unwrapped_ packet.
                ControlFlow::Continue((from, packet, Some(socket)))
            }
            // Byte is in a different range? Move on with processing the packet.
            Some(_) | None => ControlFlow::Continue((from, packet, None)),
        }
    }

    fn agents_try_handle(
        &mut self,
        from: SocketAddr,
        destination: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> ControlFlow<Result<()>> {
        let Ok(message) = StunMessage::parse(packet) else {
            return ControlFlow::Continue(());
        };

        let (_, c) = match self.connections.get_established_mut_for_stun_message(
            &message,
            &mut self.inflight_stun_requests,
            now,
        ) {
            Ok(c) => c,
            Err(e) => return ControlFlow::Break(Err(e)),
        };

        let handled = c.agent.handle_stun_packet(
            now,
            StunPacket {
                proto: "udp".try_into().expect("UDP is a valid protocol"),
                source: from,
                destination,
                message,
            },
        );

        if !handled {
            tracing::debug!(
                "Agent did not handle STUN packet assigned by local ufrag or STUN Transaction ID"
            );
        }

        ControlFlow::Break(Ok(()))
    }

    fn connections_try_handle(
        &mut self,
        from: SocketAddr,
        destination: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> ControlFlow<Result<()>, (TId, IpPacket)> {
        // If the packet is not a WireGuard packet, bail early.
        let Ok(parsed_packet) = boringtun::noise::Tunn::parse_incoming_packet(packet) else {
            tracing::debug!(packet = %hex::encode(packet));

            return ControlFlow::Break(Err(anyhow::Error::msg("Not a WireGuard packet")));
        };

        let (cid, conn) = match &parsed_packet {
            // When receiving a handshake, we need to look-up the peer by its public key because we don't have a session-index mapping yet.
            Packet::HandshakeInit(handshake_init) => {
                let handshake = match boringtun::noise::handshake::parse_handshake_anon(
                    &self.private_key,
                    &self.public_key,
                    handshake_init,
                )
                .context("Failed to parse handshake init")
                {
                    Ok(handshake) => handshake,
                    Err(e) => return ControlFlow::Break(Err(e)),
                };

                match self
                    .connections
                    .get_established_mut_by_public_key(handshake.peer_static_public, now)
                {
                    Ok(c) => c,
                    Err(e) => return ControlFlow::Break(Err(e)),
                }
            }
            // For all other packets, grab the session index and look up the corresponding connection.
            Packet::HandshakeResponse(HandshakeResponse { receiver_idx, .. })
            | Packet::PacketCookieReply(PacketCookieReply { receiver_idx, .. })
            | Packet::PacketData(PacketData { receiver_idx, .. }) => match self
                .connections
                .get_established_mut_session_index(Index::from_peer(*receiver_idx), now)
            {
                Ok(c) => c,
                Err(e) => return ControlFlow::Break(Err(e)),
            },
        };

        let control_flow = conn.decapsulate(
            cid,
            from,
            destination,
            packet,
            &mut self.allocations,
            &mut self.buffered_transmits,
            now,
        );

        if let ControlFlow::Break(Ok(())) = &control_flow
            && conn.first_handshake_completed_at.is_none()
            && matches!(
                parsed_packet,
                Packet::HandshakeInit(_) | Packet::HandshakeResponse(_)
            )
        {
            conn.first_handshake_completed_at = Some(now);

            tracing::debug!(%cid, duration_since_intent = ?conn.duration_since_intent(now), "Completed wireguard handshake");

            // Only signal establishment once we can actually send, i.e. ICE has nominated a
            // socket. On the controlled side the handshake can complete before nomination, in
            // which case the event is emitted from the `NominatedSend` handler instead.
            if conn.state.has_nominated_socket() {
                self.pending_events
                    .push_back(Event::ConnectionEstablished(cid))
            }
        }

        control_flow
            .map_continue(|c| (cid, c))
            .map_break(|b| b.with_context(|| format!("cid={cid} length={}", packet.len())))
    }

    fn allocations_drain_events(&mut self, now: Instant) {
        while let Some((rid, event)) = self.allocations.poll_event() {
            tracing::trace!(%rid, ?event);

            match event {
                allocation::Event::New(candidate) => {
                    for (cid, c) in self.connections.iter_mut_by_relay(rid) {
                        c.add_local_candidate(cid, &candidate, &mut self.pending_events, now);
                    }
                }
                allocation::Event::Invalid(candidate) => {
                    for (cid, c) in self.connections.iter_mut() {
                        c.remove_local_candidate(cid, &candidate, &mut self.pending_events, now);
                    }
                }
            }
        }
    }

    /// Sample a relay to use for a new connection.
    fn sample_relay(&mut self) -> Result<RId, NoTurnServers> {
        let rid = self.allocations.sample().ok_or(NoTurnServers {})?;

        tracing::debug!(%rid, "Sampled relay");

        Ok(rid)
    }
}

/// Seeds the agent with all local candidates, returning an iterator of all candidates that should be signalled to the remote.
fn seed_agent_with_local_candidates<'a, RId>(
    selected_relay: RId,
    agent: &'a mut Agent,
    allocations: &Allocations<RId>,
) -> impl Iterator<Item = Candidate> + use<'a, RId>
where
    RId: Ord + fmt::Display + Copy,
{
    allocations
        .candidates_for_relay(&selected_relay)
        .filter_map(move |c| agent.add_local_candidate(c))
}

/// Generate optimistic candidates based on the ones we have already received.
///
/// In order to aid the creation of peer-to-peer connections,
/// we create an additional server-reflexive candidate
/// for each combination of public IP and host listening port.
///
/// IF the listening port of the remote peer happened to be forwarded, this will
/// allow us to create a direct connection despite the presence of a symmetric NAT.
///
/// Consider the following scenario:
///
/// - Agent 1 listens on `10.0.0.1:52625` and has a public IP of `1.1.1.1`
/// - Agent 2 listens on `192.168.0.1:52625` and has a public IP of `2.2.2.2`
///
/// Both agents are behind symmetric NAT.
/// Therefore, the observed port through STUN will not be 52625 but something else entirely.
/// For this example, let's assume 40000.
///
/// Now let's assume that the network administrator forwards port 52625 on one symmetric NAT.
/// With the below strategy, agent 2 will create an additional server-reflexive candidate
/// of `1.1.1.1:52625` based on the observed public IP and the port of the host candidate.
/// This is the port forwarded by the network administrator which will allow the traffic to
/// flow through to the agent.
///
/// In a double symmetric NAT case, this will create a peer-reflexive candidate.
/// If only one peer is behind symmetric NAT, this creates a predictable path through the NAT.
///
/// In both cases, a direct connection will be established and we don't need to fall back to a relay.
fn generate_optimistic_candidates(agent: &mut Agent, now: Instant) {
    let public_ips = agent
        .remote_candidates()
        .filter_map(|c| (c.kind() == CandidateKind::ServerReflexive).then_some(c.addr().ip()))
        .collect::<SmallVec<[_; 8]>>();

    let host_candidates = agent
        .remote_candidates()
        .filter_map(|c| (c.kind() == CandidateKind::Host).then_some(c.addr()))
        .collect::<SmallVec<[_; 8]>>();

    let optimistic_candidates = public_ips
        .into_iter()
        .cartesian_product(host_candidates)
        .filter(|(ip, base)| ip.is_ipv4() && base.is_ipv4())
        .filter_map(|(ip, base)| {
            let addr = SocketAddr::new(ip, base.port());

            Candidate::server_reflexive(addr, base, "udp")
                .inspect_err(
                    |e| tracing::debug!(%addr, %base, "Failed to create optimistic candidate: {e}"),
                )
                .ok()
        })
        .filter(|c| !agent.contains_remote_candidate(c))
        .take(2)
        .collect::<SmallVec<[_; 2]>>();

    for c in optimistic_candidates {
        tracing::debug!(candidate = ?c, "Adding optimistic candidate for remote");

        agent.add_remote_candidate(c, now);
    }
}

fn new_ice_candidate_event<TId>(id: TId, candidate: Candidate, iceless: bool) -> Event<TId> {
    let candidate = crate::candidate::encode(iceless, &candidate);

    tracing::debug!(%candidate, "Signalling candidate to remote");

    Event::NewIceCandidate {
        connection: id,
        candidate,
    }
}

fn invalidate_allocation_candidates<TId, RId>(
    connections: &mut Connections<TId, RId>,
    allocation: &Allocation,
    pending_events: &mut VecDeque<Event<TId>>,
    now: Instant,
) where
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
{
    for (cid, c) in connections.iter_mut() {
        if c.agent.is_iceless() {
            c.reset_path_for_relay_replacement(cid, allocation, now);
        } else {
            for candidate in allocation.current_relay_candidates() {
                c.remove_local_candidate(cid, &candidate, pending_events, now);
            }
        }
    }
}

pub struct Credentials {
    /// The ICE username (ufrag).
    pub username: String,
    /// The ICE password.
    pub password: String,
}

#[doc(hidden)] // Not public API.
impl From<Credentials> for is::IceCreds {
    fn from(value: Credentials) -> Self {
        is::IceCreds {
            ufrag: value.username,
            pass: value.password,
        }
    }
}

#[cfg(test)]
impl From<is::IceCreds> for Credentials {
    fn from(value: is::IceCreds) -> Self {
        Credentials {
            username: value.ufrag,
            password: value.pass,
        }
    }
}

#[derive(Debug, PartialEq, Clone)]
pub enum Event<TId> {
    /// We created a new candidate for this connection and ask to signal it to the remote party.
    ///
    /// Already SDP-encoded (str0m for ICE, path-agent for ICE-less).
    NewIceCandidate {
        connection: TId,
        candidate: String,
    },

    /// We invalidated a candidate for this connection and ask to signal that to the remote party.
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

    /// We ran out of relays and need a new set to make relayed connections.
    ///
    /// Upper layers should obtain new relays and pass them to [`Node::update_relays`].
    /// Emitted at most once per set of relays provided via [`Node::update_relays`].
    NoRelays,
}

#[derive(Clone, PartialEq, PartialOrd, Eq, Ord)]
pub struct Transmit {
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
    pub payload: Buffer<Vec<u8>>,
    /// The ECN bits to set for the UDP packet.
    pub ecn: Ecn,
}

impl fmt::Debug for Transmit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Transmit")
            .field("src", &self.src)
            .field("dst", &self.dst)
            .field("len", &self.payload.len())
            .finish()
    }
}

#[derive(Debug, Clone, Copy)]
pub struct EncapsulateInfo {
    pub src: Option<SocketAddr>,
    pub dst: SocketAddr,
}

#[derive(derive_more::Debug)]
struct Connection<RId> {
    agent: Agent,

    index: Index,
    #[debug(skip)]
    tunnel: Tunn,
    remote_pub_key: PublicKey,
    /// When to next update the [`Tunn`]'s timers.
    next_wg_timer_update: Instant,

    last_proactive_handshake_sent_at: Option<Instant>,

    /// The relay we have selected for this connection.
    relay: SelectedRelay<RId>,

    state: ConnectionState,
    disconnected_at: Option<Instant>,

    stats: ConnectionStats,
    intent_sent_at: Instant,
    candidate_timeout: Option<Instant>,

    first_handshake_completed_at: Option<Instant>,

    buffer: Vec<u8>,

    default_ice_config: IceConfig,
    idle_ice_config: IceConfig,

    #[debug(skip)]
    buffer_pool: BufferPool<Vec<u8>>,

    poll_timeout_cache: TimeoutCache,
}

#[derive(Debug)]
struct SelectedRelay<RId> {
    id: RId,
}

impl<RId> Connection<RId>
where
    RId: PartialEq + Eq + Hash + fmt::Debug + fmt::Display + Copy + Ord,
{
    fn duration_since_intent(&self, now: Instant) -> Duration {
        now.duration_since(self.intent_sent_at)
    }

    #[must_use]
    fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        let timeout = iter::empty()
            .chain(
                self.agent
                    .poll_timeout()
                    .map(|instant| (instant, "ICE agent")),
            )
            .chain(Some((self.next_wg_timer_update, "boringtun tunnel")))
            .chain(
                self.candidate_timeout
                    .map(|instant| (instant, "candidate timeout")),
            )
            .chain(
                self.disconnect_timeout()
                    .map(|instant| (instant, "disconnect timeout")),
            )
            .chain(self.state.poll_timeout(&self.agent))
            .min_by_key(|(instant, _)| *instant);

        self.poll_timeout_cache.update(timeout)
    }

    fn disconnect_timeout(&self) -> Option<Instant> {
        let disconnected_at = self.disconnected_at?;

        Some(disconnected_at + DISCONNECT_TIMEOUT)
    }

    fn handle_timeout<TId>(
        &mut self,
        cid: TId,
        now: Instant,
        allocations: &mut Allocations<RId>,
        transmits: &mut TransmitBuffer,
        pending_events: &mut VecDeque<Event<TId>>,
        inflight_stun_requests: &mut InflightStunRequests<TId>,
    ) where
        TId: Copy + Ord + fmt::Display,
        RId: Copy + Ord + fmt::Display,
    {
        match self.poll_timeout_cache.check(now) {
            ControlFlow::Continue(()) => {}
            ControlFlow::Break(()) => return,
        };

        let _guard = tracing::info_span!("handle_timeout", %cid).entered();

        self.agent.handle_timeout(now);
        self.state
            .handle_timeout(&mut self.agent, self.idle_ice_config, now);

        if self.candidate_timeout.is_some_and(|timeout| now >= timeout) {
            tracing::info!(state = %self.state, index = %self.index.global(), "Connection failed (no candidates received)");
            self.state = ConnectionState::Failed;
            return;
        }

        if self
            .disconnect_timeout()
            .is_some_and(|timeout| now >= timeout)
        {
            tracing::info!(state = %self.state, index = %self.index.global(), "Connection failed (ICE timeout)");
            self.state = ConnectionState::Failed;
            return;
        }

        self.handle_tunnel_timeout(now, allocations, transmits);

        // If this was a scheduled update, hop to the next interval.
        if now >= self.next_wg_timer_update {
            self.next_wg_timer_update = now + Duration::from_secs(1); // TODO: Remove fixed interval in favor of precise `next_timer_update` function in `boringtun`.
        }

        // If `boringtun` wants to be called earlier than the scheduled interval, move it forward.
        if let Some(next_update) = self.tunnel.next_timer_update()
            && next_update < self.next_wg_timer_update
        {
            self.next_wg_timer_update = next_update;
        }

        while let Some(event) = self.agent.poll_ice_event() {
            match event {
                IceAgentEvent::DiscoveredRecv { .. } => {}
                IceAgentEvent::IceConnectionStateChange(IceConnectionState::Disconnected) => {
                    tracing::debug!(grace_period = ?DISCONNECT_TIMEOUT, "Received ICE disconnect");

                    self.disconnected_at = Some(now);
                }
                IceAgentEvent::IceConnectionStateChange(
                    IceConnectionState::Checking | IceConnectionState::Connected,
                ) => {
                    let existing = self.disconnected_at.take();

                    if let Some(disconnected_at) = existing {
                        let offline = now.duration_since(disconnected_at);

                        tracing::debug!(?offline, "ICE agent reconnected");
                    }
                }
                IceAgentEvent::NominatedSend {
                    destination,
                    source,
                    ..
                } => {
                    if let Some((r, _)) = allocations.get_mut_by_allocation(source)
                        && self.relay.id != r
                    {
                        tracing::warn!(
                            "Nominated a relay different from what we set out to! Weird?"
                        );
                    }

                    let remote_socket =
                        self.peer_socket_for_tuple(allocations, source, destination);

                    let old = match mem::replace(&mut self.state, ConnectionState::Failed) {
                        ConnectionState::Connecting { wg_buffer } => {
                            tracing::debug!(
                                num_buffered = %wg_buffer.len(),
                                "Flushing WireGuard packets buffered during ICE"
                            );

                            transmits.extend(wg_buffer.into_iter().flat_map(|packet| {
                                make_owned_transmit(
                                    self.relay.id,
                                    remote_socket,
                                    &packet,
                                    &self.buffer_pool,
                                    allocations,
                                    now,
                                )
                            }));

                            self.state = ConnectionState::Connected {
                                peer_socket: remote_socket,
                                last_activity: now,
                            };

                            // If the WireGuard handshake already completed while we were still
                            // running ICE, the connection only becomes usable now that a socket is
                            // nominated, so this is when we signal establishment.
                            if self.first_handshake_completed_at.is_some() {
                                pending_events.push_back(Event::ConnectionEstablished(cid));
                            }

                            None
                        }
                        ConnectionState::Connected {
                            peer_socket,
                            last_activity,
                        } if peer_socket == remote_socket => {
                            self.state = ConnectionState::Connected {
                                peer_socket,
                                last_activity,
                            };

                            continue; // If we re-nominate the same socket, don't just continue. TODO: Should this be fixed upstream?
                        }
                        ConnectionState::Connected {
                            peer_socket,
                            last_activity,
                        } => {
                            self.state = ConnectionState::Connected {
                                peer_socket: remote_socket,
                                last_activity,
                            };

                            Some(peer_socket)
                        }
                        ConnectionState::Idle { peer_socket } => {
                            self.state = ConnectionState::Idle {
                                peer_socket: remote_socket,
                            };

                            Some(peer_socket)
                        }
                        ConnectionState::Failed => continue, // Failed connections are cleaned up, don't bother handling events.
                    };

                    let relay = self.relay.id;

                    tracing::info!(
                        old = old.map(|s| s.fmt(relay)).map(tracing::field::display),
                        new = %remote_socket.fmt(relay),
                        duration_since_intent = ?self.duration_since_intent(now),
                        "Updating remote socket"
                    );

                    if self.agent.send_wg_handshake_after_nomination() {
                        self.initiate_wg_session(allocations, transmits, now);
                    }
                }
                IceAgentEvent::IceRestart(_) | IceAgentEvent::IceConnectionStateChange(_) => {}
            }
        }

        while let Some(event) = self.agent.poll_path_event() {
            match event {
                path_agent::Event::PrimaryChanged { local, remote } => {
                    let peer_socket = self.peer_socket_for_tuple(allocations, local, remote);
                    self.adopt_iceless_peer_socket(
                        peer_socket,
                        allocations,
                        transmits,
                        pending_events,
                        cid,
                        now,
                    );
                }
            }
        }

        // Plaintext payloads (probes) need encapsulation; ciphertext
        // goes straight to the wire.
        while let Some(pt) = self.agent.poll_path_transmit() {
            let peer_socket = self.peer_socket_for_tuple(allocations, pt.local, pt.remote);
            match pt.payload {
                path_agent::Payload::Ciphertext(ref bytes) => {
                    if let Some(transmit) = make_owned_transmit(
                        self.relay.id,
                        peer_socket,
                        bytes,
                        &self.buffer_pool,
                        allocations,
                        now,
                    ) {
                        transmits.push(transmit);
                    }
                }
                path_agent::Payload::Plaintext(ref ip) => {
                    let _ = self.encapsulate(cid, peer_socket, ip, now, allocations, transmits);
                }
            }
        }

        while let Some(transmit) = self.agent.poll_ice_transmit() {
            let source = transmit.source;
            let dst = transmit.destination;
            let stun_packet_bytes = Vec::from(transmit.contents);
            match StunMessage::parse(&stun_packet_bytes) {
                Ok(msg) if msg.is_binding_request() => {
                    inflight_stun_requests.add(cid, msg.trans_id(), now);
                }
                Ok(_) => {}
                Err(e) => {
                    tracing::warn!("`is` emitted invalid STUN message: {e}")
                }
            }

            // Check if `is` wants us to send from a "remote" socket, i.e. one that we allocated with a relay.
            let Some((relay, allocation)) = allocations.get_mut_by_allocation(source) else {
                self.stats.stun_bytes_to_peer_direct += stun_packet_bytes.len();

                // `source` did not match any of our allocated sockets, must be a local one then!
                transmits.push(Transmit {
                    src: Some(source),
                    dst,
                    payload: self.buffer_pool.pull_initialised(&stun_packet_bytes),
                    ecn: Ecn::NonEct,
                });
                continue;
            };

            let mut data_channel_packet = channel_data_packet_buffer(&stun_packet_bytes);

            // Payload should be sent from a "remote socket", let's wrap it in a channel data message!
            let Some(encode_ok) =
                allocation.encode_channel_data_header(dst, &mut data_channel_packet, now)
            else {
                // Unlikely edge-case, drop the packet and continue.
                tracing::trace!(%relay, peer = %dst, "Dropping packet because allocation does not offer a channel to peer");
                continue;
            };

            self.stats.stun_bytes_to_peer_relayed += data_channel_packet.len();

            transmits.push(Transmit {
                src: None,
                dst: encode_ok.socket,
                payload: self.buffer_pool.pull_initialised(&data_channel_packet),
                ecn: Ecn::NonEct,
            });
        }
    }

    fn handle_tunnel_timeout(
        &mut self,
        now: Instant,
        allocations: &mut Allocations<RId>,
        transmits: &mut TransmitBuffer,
    ) {
        /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
        ///
        /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
        const MAX_SCRATCH_SPACE: usize = 148;

        let mut buf = [0u8; MAX_SCRATCH_SPACE];

        // Advance unconditionally — even in `Connecting` — so a stuck
        // bootstrap eventually surfaces `ConnectionExpired` instead of
        // hanging.
        match self.tunnel.update_timers_at(&mut buf, now) {
            TunnResult::Done => {}
            TunnResult::Err(WireGuardError::ConnectionExpired) => {
                tracing::info!(state = %self.state, index = %self.index.global(), "Connection failed (wireguard tunnel expired)");
                self.state = ConnectionState::Failed;
            }
            TunnResult::Err(e) => {
                tracing::warn!("boringtun error: {e}");
            }
            TunnResult::WriteToNetwork(b) => {
                if self.agent.is_iceless() {
                    self.agent.handle_outbound(b.to_vec(), now);
                } else if let Some(peer_socket) = self.socket() {
                    transmits.extend(make_owned_transmit(
                        self.relay.id,
                        peer_socket,
                        b,
                        &self.buffer_pool,
                        allocations,
                        now,
                    ));
                }
            }
            TunnResult::WriteToTunnelV4(..) | TunnResult::WriteToTunnelV6(..) => {
                panic!("Unexpected result from update_timers")
            }
        };
    }

    fn adopt_iceless_peer_socket<TId>(
        &mut self,
        peer_socket: PeerSocket,
        allocations: &mut Allocations<RId>,
        transmits: &mut TransmitBuffer,
        pending_events: &mut VecDeque<Event<TId>>,
        cid: TId,
        now: Instant,
    ) where
        TId: Copy + fmt::Display,
    {
        match mem::replace(&mut self.state, ConnectionState::Failed) {
            ConnectionState::Connecting { wg_buffer } => {
                tracing::debug!(
                    %cid,
                    num_wg = wg_buffer.len(),
                    "Iceless primary selected; flushing buffered packets",
                );
                transmits.extend(wg_buffer.into_iter().flat_map(|packet| {
                    make_owned_transmit(
                        self.relay.id,
                        peer_socket,
                        &packet,
                        &self.buffer_pool,
                        allocations,
                        now,
                    )
                }));
                self.state = ConnectionState::Connected {
                    peer_socket,
                    last_activity: now,
                };

                // The connection only becomes usable now that a socket is
                // selected, so this is when we signal establishment if the
                // WireGuard handshake already completed.
                if self.first_handshake_completed_at.is_some() {
                    pending_events.push_back(Event::ConnectionEstablished(cid));
                }
            }
            ConnectionState::Connected {
                peer_socket: old,
                last_activity,
            } => {
                if old != peer_socket {
                    tracing::info!(%cid, ?old, new = ?peer_socket, "Updating peer socket");
                }
                self.state = ConnectionState::Connected {
                    peer_socket,
                    last_activity,
                };
            }
            ConnectionState::Idle { peer_socket: old } => {
                if old != peer_socket {
                    tracing::info!(%cid, ?old, new = ?peer_socket, "Updating peer socket");
                }
                self.state = ConnectionState::Idle { peer_socket };
            }
            ConnectionState::Failed => {
                self.state = ConnectionState::Failed;
            }
        }
    }

    /// Encapsulate `packet` directly into the buffer handed out by `provider`, avoiding a copy.
    fn encapsulate<TId>(
        &mut self,
        cid: TId,
        socket: PeerSocket,
        packet: &IpPacket,
        now: Instant,
        allocations: &mut Allocations<RId>,
        provider: &mut impl BufferProvider,
    ) -> Result<Option<EncapsulateInfo>>
    where
        TId: fmt::Display,
    {
        self.state
            .on_outgoing(cid, &mut self.agent, self.default_ice_config, packet, now);

        let relay_id = self.relay.id;
        let ecn = packet.ecn();

        let (src, dst, packet_start, relay) = match socket {
            PeerSocket::PeerToPeer { source, dest } | PeerSocket::PeerToRelay { source, dest } => {
                (Some(source), dest, 0, None)
            }
            PeerSocket::RelayToPeer { dest: peer } | PeerSocket::RelayToRelay { dest: peer } => {
                let allocation = allocations
                    .get_mut_by_id(&relay_id)
                    .with_context(|| format!("No allocation for relay {relay_id}"))?;
                let dst = allocation
                    .active_socket()
                    .with_context(|| format!("No active socket for relay {relay_id}"))?;

                (
                    None,
                    dst,
                    ip_packet::DATA_CHANNEL_OVERHEAD,
                    Some((peer, allocation)),
                )
            }
        };

        let reserve_len = packet_start + packet.packet().len() + ip_packet::WG_OVERHEAD;
        let mut reservation = provider.reserve(src, dst, ecn, reserve_len);

        // On `Err`, `reservation` is dropped without committing and rolls back automatically.
        let len = self.tunnel.encapsulate_data_at(
            packet.packet(),
            &mut reservation.buffer()[packet_start..],
            now,
        )?;
        debug_assert_eq!(packet_start + len, reserve_len);

        if let Some((peer, allocation)) = relay {
            // A missing channel is an expected part of channel setup (`encode_channel_data_header`
            // logs it and queues a binding), so drop the packet instead of surfacing an error.
            if allocation
                .encode_channel_data_header(peer, reservation.buffer(), now)
                .is_none()
            {
                return Ok(None);
            }
        }

        reservation.commit();

        Ok(Some(EncapsulateInfo { src, dst }))
    }

    fn decapsulate<TId>(
        &mut self,
        cid: TId,
        from: SocketAddr,
        destination: SocketAddr,
        packet: &[u8],
        allocations: &mut Allocations<RId>,
        transmits: &mut TransmitBuffer,
        now: Instant,
    ) -> ControlFlow<Result<()>, IpPacket>
    where
        TId: fmt::Display,
        RId: Ord + fmt::Display + Copy,
    {
        let packet = match self.agent.handle_inbound_network(
            &mut self.tunnel,
            packet,
            (destination, from),
            now,
        ) {
            ControlFlow::Break(()) => return ControlFlow::Break(Ok(())),
            ControlFlow::Continue(packet) => packet,
        };

        let mut ip_packet = IpPacketBuf::new();

        let control_flow = match self.tunnel.decapsulate_at(
            Some(from.ip()),
            packet,
            ip_packet.buf(),
            now,
        ) {
            TunnResult::Done => ControlFlow::Break(Ok(())),
            TunnResult::Err(e) if crate::is_handshake(packet) => {
                ControlFlow::Break(Err(anyhow::Error::new(e).context("handshake packet")))
            }
            TunnResult::Err(e) => ControlFlow::Break(Err(anyhow::Error::new(e))),

            // For WriteToTunnel{V4,V6}, boringtun returns the source IP of the packet that was tunneled to us.
            // I am guessing this was done for convenience reasons.
            // In our API, we parse the packets directly as an IpPacket.
            // Thus, the caller can query whatever data they'd like, not just the source IP so we don't return it in addition.
            TunnResult::WriteToTunnelV4(packet, ip) => {
                let packet_len = packet.len();

                match IpPacket::new(ip_packet, packet_len).context("Failed to parse IP packet") {
                    Ok(p) => {
                        debug_assert_eq!(p.source(), IpAddr::V4(ip));

                        ControlFlow::Continue(p)
                    }
                    Err(e) => ControlFlow::Break(Err(e)),
                }
            }
            TunnResult::WriteToTunnelV6(packet, ip) => {
                let packet_len = packet.len();

                match IpPacket::new(ip_packet, packet_len).context("Failed to parse IP packet") {
                    Ok(p) => {
                        debug_assert_eq!(p.source(), IpAddr::V6(ip));

                        ControlFlow::Continue(p)
                    }
                    Err(e) => ControlFlow::Break(Err(e)),
                }
            }

            // During normal operation, i.e. when the tunnel is active, decapsulating a packet straight yields the decrypted packet.
            // However, in case `Tunn` has buffered packets, they may be returned here instead.
            // This should be fairly rare which is why we just allocate these and return them from `poll_transmit` instead.
            // Overall, this results in a much nicer API for our caller and should not affect performance.
            TunnResult::WriteToNetwork(bytes) => {
                match &mut self.state {
                    ConnectionState::Connecting { wg_buffer, .. } => {
                        tracing::debug!(%cid, "No socket has been nominated yet, buffering WG packet");

                        wg_buffer.enqueue(bytes.to_owned());

                        while let TunnResult::WriteToNetwork(packet) =
                            self.tunnel
                                .decapsulate_at(None, &[], self.buffer.as_mut(), now)
                        {
                            wg_buffer.enqueue(packet.to_owned());
                        }
                    }
                    ConnectionState::Connected { peer_socket, .. }
                    | ConnectionState::Idle { peer_socket } => {
                        transmits.extend(make_owned_transmit(
                            self.relay.id,
                            *peer_socket,
                            bytes,
                            &self.buffer_pool,
                            allocations,
                            now,
                        ));

                        while let TunnResult::WriteToNetwork(packet) =
                            self.tunnel
                                .decapsulate_at(None, &[], self.buffer.as_mut(), now)
                        {
                            transmits.extend(make_owned_transmit(
                                self.relay.id,
                                *peer_socket,
                                packet,
                                &self.buffer_pool,
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

        match control_flow {
            ControlFlow::Continue(packet) => {
                self.state
                    .on_incoming(cid, &mut self.agent, self.default_ice_config, &packet, now);

                self.agent
                    .handle_inbound_tun(packet, (destination, from), now)
                    .map_break(Ok)
            }
            ControlFlow::Break(b) => ControlFlow::Break(b),
        }
    }

    fn peer_socket_for_tuple(
        &self,
        allocations: &mut Allocations<RId>,
        local: SocketAddr,
        from: SocketAddr,
    ) -> PeerSocket
    where
        RId: Ord + fmt::Display + Copy,
    {
        let source_relay = allocations.get_mut_by_allocation(local).map(|(r, _)| r);
        let dest_is_relay = self.agent.remote_candidate_is_relayed(from);

        match (source_relay, dest_is_relay) {
            (None, false) => PeerSocket::PeerToPeer {
                source: local,
                dest: from,
            },
            (None, true) => PeerSocket::PeerToRelay {
                source: local,
                dest: from,
            },
            (Some(_), false) => PeerSocket::RelayToPeer { dest: from },
            (Some(_), true) => PeerSocket::RelayToRelay { dest: from },
        }
    }

    fn initiate_wg_session_for_path(&mut self, now: Instant)
    where
        RId: Ord + fmt::Display + Copy,
    {
        self.agent.initiate_handshake(&mut self.tunnel, false, now);
    }

    /// Iceless-only soft roam: drop all locals, force-resend the init.
    /// Connection state (peer_socket, WG session keys) stays put.
    fn reset_for_roam(&mut self, now: Instant)
    where
        RId: Ord + fmt::Display + Copy,
    {
        self.agent.rebuild_path(|_| true, now);
        self.agent.initiate_handshake(&mut self.tunnel, true, now);
    }

    /// Iceless-only. Receiver rediscovers the connection by the
    /// init's sender pubkey.
    fn reset_path_for_relay_replacement<TId>(
        &mut self,
        cid: TId,
        allocation: &Allocation,
        now: Instant,
    ) where
        TId: fmt::Display,
        RId: Ord + fmt::Display + Copy,
    {
        debug_assert!(
            self.agent.is_iceless(),
            "reset_path_for_relay_replacement is iceless-only"
        );

        // Host + reflexive per allocation.
        let dropped = allocation
            .current_relay_candidates()
            .map(|c| crate::candidate::to_path_agent(&c))
            .collect::<SmallVec<[_; 2]>>();
        self.agent.rebuild_path(|c| dropped.contains(c), now);

        self.agent.initiate_handshake(&mut self.tunnel, true, now);

        tracing::info!(%cid, "Reset iceless path-agent after relay invalidation");
    }

    fn initiate_wg_session(
        &mut self,
        allocations: &mut Allocations<RId>,
        provider: &mut impl BufferProvider,
        now: Instant,
    ) where
        RId: Copy,
    {
        let Some(socket) = self.socket() else {
            tracing::debug!("Cannot initiate WG session without a socket");
            return;
        };

        // If we have sent a handshake in the last 20s, don't bother making a new session.
        // Our re-key timeout is 15s, meaning if more than 20s have passed and we are still
        // here, we have a working connection and can refresh it.
        if let Some(last_handshake) = self
            .last_proactive_handshake_sent_at
            .map(|last_sent_at| now.duration_since(last_sent_at))
            && last_handshake < Duration::from_secs(20)
        {
            tracing::debug!(?last_handshake, "Suppressing repeated handshake");

            return;
        }

        /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
        ///
        /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
        const MAX_SCRATCH_SPACE: usize = 148;

        let mut buf = [0u8; MAX_SCRATCH_SPACE];

        let TunnResult::WriteToNetwork(bytes) = self
            .tunnel
            .format_handshake_initiation_at(&mut buf, false, now)
        else {
            tracing::debug!("Another handshake is already in progress");

            return;
        };

        self.last_proactive_handshake_sent_at = Some(now);

        if let Some(transmit) = make_owned_transmit(
            self.relay.id,
            socket,
            bytes,
            &self.buffer_pool,
            allocations,
            now,
        ) {
            provider.push(transmit);
        }
    }

    fn add_local_candidate<TId>(
        &mut self,
        cid: TId,
        candidate: &Candidate,
        pending_events: &mut VecDeque<Event<TId>>,
        now: Instant,
    ) where
        TId: fmt::Display + Copy,
    {
        if let Some(candidate) = self.agent.add_local_candidate(candidate.clone()) {
            let iceless = self.agent.is_iceless();
            pending_events.push_back(new_ice_candidate_event(cid, candidate, iceless));
        }

        self.state
            .on_candidate(cid, &mut self.agent, self.default_ice_config, now);
    }

    fn remove_local_candidate<TId>(
        &mut self,
        id: TId,
        candidate: &Candidate,
        pending_events: &mut VecDeque<Event<TId>>,
        now: Instant,
    ) where
        TId: fmt::Display,
    {
        if candidate.kind() != CandidateKind::Relayed {
            debug_assert_eq!(
                candidate.kind(),
                CandidateKind::Relayed,
                "we should only ever invalidate relay candidates"
            );
            return;
        }

        let was_present = self.agent.invalidate_candidate(candidate, now);

        if was_present {
            pending_events.push_back(Event::InvalidateIceCandidate {
                connection: id,
                candidate: crate::candidate::encode(self.agent.is_iceless(), candidate),
            })
        }
    }

    fn add_remote_candidate<TId>(&mut self, cid: TId, candidate: Candidate, now: Instant)
    where
        TId: fmt::Display,
    {
        self.agent.add_remote_candidate(candidate, now);
        self.candidate_timeout = None;

        generate_optimistic_candidates(&mut self.agent, now);

        // Make sure we move out of idle mode when we add new candidates.
        self.state
            .on_candidate(cid, &mut self.agent, self.default_ice_config, now);
    }

    fn remove_remote_candidate<TId>(&mut self, cid: TId, candidate: Candidate, now: Instant)
    where
        TId: fmt::Display,
    {
        self.agent.invalidate_candidate(&candidate, now);
        self.agent.handle_timeout(now); // We may have invalidated the last candidate, ensure we check our nomination state.

        self.state
            .on_candidate(cid, &mut self.agent, self.default_ice_config, now)
    }

    fn socket(&self) -> Option<PeerSocket> {
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

    fn migrate_relay<TId>(
        &mut self,
        cid: TId,
        new_relay: RId,
        allocations: &Allocations<RId>,
        pending_events: &mut VecDeque<Event<TId>>,
        now: Instant,
    ) where
        TId: fmt::Display + Copy,
    {
        tracing::info!(%cid, old = %self.relay.id, new = %new_relay, "Attempting to migrate connection to new relay");

        self.relay.id = new_relay;

        // The full set, not just the relay candidates: a roam wipes the agent's
        // locals, so host and reflexive candidates need re-seeding too.
        // The agent dedups, so candidates it already knows are not re-signalled.
        for candidate in allocations.candidates_for_relay(&new_relay) {
            self.add_local_candidate(cid, &candidate, pending_events, now);
        }
    }
}

#[must_use]
fn make_owned_transmit<RId>(
    relay: RId,
    socket: PeerSocket,
    message: &[u8],
    buffer_pool: &BufferPool<Vec<u8>>,
    allocations: &mut Allocations<RId>,
    now: Instant,
) -> Option<Transmit>
where
    RId: Ord + fmt::Display + Copy,
{
    let transmit = match socket {
        PeerSocket::PeerToPeer {
            dest: remote,
            source,
        }
        | PeerSocket::PeerToRelay {
            dest: remote,
            source,
        } => Transmit {
            src: Some(source),
            dst: remote,
            payload: buffer_pool.pull_initialised(message),
            ecn: Ecn::NonEct,
        },
        PeerSocket::RelayToPeer { dest: peer } | PeerSocket::RelayToRelay { dest: peer } => {
            let allocation = allocations.get_mut_by_id(&relay)?;

            let mut channel_data = channel_data_packet_buffer(message);
            let encode_ok = allocation.encode_channel_data_header(peer, &mut channel_data, now)?;

            Transmit {
                src: None,
                dst: encode_ok.socket,
                payload: buffer_pool.pull_initialised(&channel_data),
                ecn: Ecn::NonEct,
            }
        }
    };

    Some(transmit)
}

fn new_agent(role: IceRole) -> IceAgent {
    let mut agent = IceAgent::new(is::IceCreds::new());
    agent.set_controlling(matches!(role, IceRole::Controlling));
    agent.set_timing_advance(Duration::ZERO);

    agent
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};

    use super::*;

    #[test]
    fn client_default_ice_timeout() {
        let mut agent = new_agent(IceRole::Controlling);

        IceConfig::client_default().apply(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_millis(16500))
    }

    // Our WireGuard rekey attempt time must be greater than the ICE timeout,
    // otherwise we cannot migrate an existing tunnel to a new candidate pair.
    #[test]
    fn client_default_ice_timeout_less_than_wg_rekey_attempt_time() {
        let mut agent = new_agent(IceRole::Controlling);

        IceConfig::client_default().apply(&mut agent);

        assert!(agent.ice_timeout() < WG_REKEY_ATTEMPT_TIME)
    }

    #[test]
    fn client_idle_ice_timeout() {
        let mut agent = new_agent(IceRole::Controlling);

        IceConfig::client_idle().apply(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_secs(100))
    }

    #[test]
    fn server_default_ice_timeout() {
        let mut agent = new_agent(IceRole::Controlling);

        IceConfig::server_default().apply(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_millis(615_500))
    }

    #[test]
    fn server_idle_ice_timeout() {
        let mut agent = new_agent(IceRole::Controlling);

        IceConfig::server_idle().apply(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_secs(1000))
    }

    #[test]
    fn generates_correct_optimistic_candidates() {
        let base = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 1), 52625));
        let addr = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1));

        let host = Candidate::host(base, "udp").unwrap();
        let srvflx =
            Candidate::server_reflexive(SocketAddr::new(addr, 40000), base, "udp").unwrap();

        let now = Instant::now();
        let mut agent = Agent::ice(IceAgent::new(is::IceCreds::new()));
        agent.add_remote_candidate(host, now);
        agent.add_remote_candidate(srvflx, now);

        generate_optimistic_candidates(&mut agent, now);

        let expected_candidate =
            Candidate::server_reflexive(SocketAddr::new(addr, 52625), base, "udp").unwrap();

        assert!(agent.remote_candidates().contains(&expected_candidate))
    }

    #[test]
    fn skips_optimistic_candidates_for_ipv6() {
        let base = SocketAddr::V6(SocketAddrV6::new(
            Ipv6Addr::new(10, 0, 0, 0, 0, 0, 0, 1),
            52625,
            0,
            0,
        ));
        let addr = IpAddr::V6(Ipv6Addr::new(1, 1, 1, 1, 1, 1, 1, 1));

        let host = Candidate::host(base, "udp").unwrap();
        let srvflx =
            Candidate::server_reflexive(SocketAddr::new(addr, 40000), base, "udp").unwrap();

        let now = Instant::now();
        let mut agent = Agent::ice(IceAgent::new(is::IceCreds::new()));
        agent.add_remote_candidate(host, now);
        agent.add_remote_candidate(srvflx, now);

        generate_optimistic_candidates(&mut agent, now);

        let unexpected_candidate =
            Candidate::server_reflexive(SocketAddr::new(addr, 52625), base, "udp").unwrap();

        assert!(!agent.remote_candidates().contains(&unexpected_candidate))
    }

    #[test]
    fn limits_optimistic_ipv4_candidates_to_2() {
        let base = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 1), 52625));
        let addr1 = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1));
        let addr2 = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 2));
        let addr3 = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 3));

        let host = Candidate::host(base, "udp").unwrap();
        let srflx1 =
            Candidate::server_reflexive(SocketAddr::new(addr1, 40000), base, "udp").unwrap();
        let srflx2 =
            Candidate::server_reflexive(SocketAddr::new(addr2, 40000), base, "udp").unwrap();
        let srflx3 =
            Candidate::server_reflexive(SocketAddr::new(addr3, 40000), base, "udp").unwrap();

        let now = Instant::now();
        let mut agent = Agent::ice(IceAgent::new(is::IceCreds::new()));
        agent.add_remote_candidate(host, now);
        agent.add_remote_candidate(srflx1, now);
        agent.add_remote_candidate(srflx2, now);
        agent.add_remote_candidate(srflx3, now);

        generate_optimistic_candidates(&mut agent, now);

        let expected_candidate1 =
            Candidate::server_reflexive(SocketAddr::new(addr1, 52625), base, "udp").unwrap();
        let expected_candidate2 =
            Candidate::server_reflexive(SocketAddr::new(addr2, 52625), base, "udp").unwrap();
        let unexpected_candidate3 =
            Candidate::server_reflexive(SocketAddr::new(addr3, 52625), base, "udp").unwrap();

        assert!(agent.remote_candidates().contains(&expected_candidate1));
        assert!(agent.remote_candidates().contains(&expected_candidate2));
        assert!(!agent.remote_candidates().contains(&unexpected_candidate3));
    }
}
