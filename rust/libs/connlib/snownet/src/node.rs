mod allocations;
mod connections;

pub use connections::UnknownConnection;

use crate::allocation::{self, Allocation, RelaySocket, Socket};
use crate::index::IndexLfsr;
use crate::node::allocations::Allocations;
use crate::node::connections::Connections;
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
use hex_display::HexDisplayExt;
use ip_packet::{Ecn, IpPacket, IpPacketBuf};
use itertools::Itertools;
use rand::rngs::StdRng;
use rand::{RngCore, SeedableRng};
use ringbuffer::{AllocRingBuffer, RingBuffer as _};
use sha2::Digest;
use std::collections::BTreeSet;
use std::hash::Hash;
use std::net::IpAddr;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};
use std::{collections::VecDeque, net::SocketAddr, sync::Arc};
use std::{iter, mem};
use str0m::ice::{IceAgent, IceAgentEvent, IceCreds, StunMessage, StunPacket};
use str0m::net::Protocol;
use str0m::{Candidate, CandidateKind, IceConnectionState};
use stun_codec::rfc5389::attributes::{Realm, Username};

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

/// How long we will at most wait for a candidate from the remote.
const CANDIDATE_TIMEOUT: Duration = Duration::from_secs(10);

/// Grace-period for when we will act on an ICE disconnect.
const DISCONNECT_TIMEOUT: Duration = Duration::from_secs(2);

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

enum RoleKind {
    Client,
    Server,
}

trait Role {
    fn new() -> Self;
    fn kind(&self) -> RoleKind;
}

impl Role for Server {
    fn new() -> Self {
        Self {}
    }

    fn kind(&self) -> RoleKind {
        RoleKind::Server
    }
}

impl Role for Client {
    fn new() -> Self {
        Self {}
    }

    fn kind(&self) -> RoleKind {
        RoleKind::Client
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
/// - `T`: The role it is operating in, either [`Client`] or [`Server`].
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

    buffered_transmits: VecDeque<Transmit>,

    next_rate_limiter_reset: Option<Instant>,

    allocations: Allocations<RId>,

    connections: Connections<TId, RId>,
    pending_events: VecDeque<Event<TId>>,

    stats: NodeStats,
    buffer_pool: BufferPool<Vec<u8>>,

    role: T,
    rng: StdRng,

    /// The number of seconds since the UNIX epoch.
    unix_ts: Duration,
    /// The [`Instant`] at the time we read the UNIX epoch above.
    unix_now: Instant,
}

#[derive(thiserror::Error, Debug)]
#[error("No TURN servers available")]
pub struct NoTurnServers {}

#[expect(private_bounds, reason = "We don't want `Role` to be public API")]
impl<T, TId, RId> Node<T, TId, RId>
where
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
    T: Role,
{
    pub fn new(seed: [u8; 32], now: Instant, unix_ts: Duration) -> Self {
        let mut rng = StdRng::from_seed(seed);
        let private_key = StaticSecret::random_from_rng(&mut rng);
        let public_key = &(&private_key).into();
        let index = IndexLfsr::new(&mut rng);

        Self {
            rng,
            session_id: SessionId::new(*public_key),
            private_key,
            public_key: *public_key,
            role: T::new(),
            index,
            rate_limiter: Arc::new(RateLimiter::new_at(public_key, HANDSHAKE_RATE_LIMIT, now)),
            buffered_transmits: VecDeque::default(),
            next_rate_limiter_reset: None,
            pending_events: VecDeque::default(),
            allocations: Default::default(),
            connections: Default::default(),
            stats: Default::default(),
            buffer_pool: BufferPool::new(ip_packet::MAX_FZ_PAYLOAD, "snownet"),
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

        let closed_connections = self
            .connections
            .iter_ids()
            .map(Event::ConnectionClosed)
            .collect::<Vec<_>>();
        let num_connections = closed_connections.len();

        self.pending_events.extend(closed_connections);

        self.connections.clear();
        self.buffered_transmits.clear();

        self.private_key = StaticSecret::random_from_rng(&mut self.rng);
        self.public_key = (&self.private_key).into();
        self.rate_limiter = Arc::new(RateLimiter::new_at(
            &self.public_key,
            HANDSHAKE_RATE_LIMIT,
            now,
        ));
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
        preshared_key: x25519::StaticSecret,
        local_creds: Credentials,
        remote_creds: Credentials,
        now: Instant,
    ) -> Result<(), NoTurnServers> {
        let local_creds = local_creds.into();
        let remote_creds = remote_creds.into();

        if self.connections.contains_initial(&cid) {
            debug_assert!(
                false,
                "The new `upsert_connection` API is incompatible with the previous `new_connection` API"
            );
            return Ok(());
        }

        // Check if we already have a connection with the exact same parameters.
        // In order for the connection to be same, we need to compare:
        // - Local ICE credentials
        // - Remote ICE credentials
        // - Remote public key
        // - Preshared key
        //
        // Only if all of those things are the same, will:
        // - ICE be able to establish a connection
        // - boringtun be able to handshake a session
        if let Ok(c) = self.connections.get_established_mut(&cid, now)
            && c.agent.local_credentials() == &local_creds
            && c.agent
                .remote_credentials()
                .is_some_and(|c| c == &remote_creds)
            && c.tunnel.remote_static_public() == remote
            && c.tunnel.preshared_key().as_bytes() == preshared_key.as_bytes()
        {
            tracing::info!(local = ?local_creds, "Reusing existing connection");

            c.state.on_upsert(cid, &mut c.agent, now);

            // Take all current candidates.
            let current_candidates = c.agent.local_candidates().to_vec();

            // Re-seed connection with all candidates.
            let new_candidates =
                seed_agent_with_local_candidates(c.relay.id, &mut c.agent, &self.allocations);

            // Tell the remote about all of them.
            self.pending_events.extend(
                std::iter::empty()
                    .chain(current_candidates)
                    .chain(new_candidates)
                    .map(|candidate| new_ice_candidate_event(cid, candidate)),
            );

            // Initiate a new WG session.
            //
            // We can have up to 8 concurrent WireGuard sessions in boringtun before the oldest one gets overwritten.
            // Also, whilst we are handshaking a new session, we won't send another handshake.
            // Thus, even rapid successive connection upserts should be handled just fine.
            if c.agent.controlling() {
                c.initiate_wg_session(&mut self.allocations, &mut self.buffered_transmits, now);
            }

            return Ok(());
        }

        let selected_relay = self.sample_relay()?;

        let existing = self.connections.remove_established(&cid, now);
        let index = self.index.next();

        if let Some(existing) = existing {
            let current_local = existing.agent.local_credentials();
            tracing::info!(?current_local, new_local = ?local_creds, remote = ?remote_creds, %index, "Replacing existing connection");
        } else {
            tracing::info!(local = ?local_creds, remote = ?remote_creds, %index, "Creating new connection");
        }

        let mut agent = match self.role.kind() {
            RoleKind::Client => new_client_agent(),
            RoleKind::Server => new_server_agent(),
        };
        agent.set_local_credentials(local_creds);
        agent.set_remote_credentials(remote_creds);

        self.pending_events.extend(
            self.allocations
                .candidates_for_relay(&selected_relay)
                .filter_map(|candidate| {
                    add_local_candidate(&mut agent, candidate)
                        .map(|c| new_ice_candidate_event(cid, c))
                }),
        );

        let connection = self.init_connection(
            cid,
            agent,
            remote,
            preshared_key,
            selected_relay,
            index,
            now,
            now,
        );

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

        match connection.encapsulate(cid, peer_socket, &goodbye, now, &mut self.allocations) {
            Ok(Some(transmit)) => {
                tracing::info!("Connection closed proactively (sent goodbye)");

                self.buffered_transmits.push_back(transmit);
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
    pub fn add_remote_candidate(&mut self, cid: TId, candidate: Candidate, now: Instant) {
        let Some((agent, maybe_state, relay)) = self.connections.agent_and_state_mut(cid) else {
            tracing::debug!(ignored_candidate = %candidate, "Unknown connection");
            return;
        };

        tracing::debug!(?candidate, "Received candidate from remote");

        agent.add_remote_candidate(candidate.clone());

        generate_optimistic_candidates(agent);

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

        let Some(allocation) = self.allocations.get_mut_by_id(&relay) else {
            tracing::debug!(rid = %relay, "Unknown relay");
            return;
        };

        allocation.bind_channel(candidate.addr(), now);

        if let Some(state) = maybe_state {
            // Make sure we move out of idle mode when we add new candidates.
            state.on_candidate(cid, agent, now);
        };
    }

    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn remove_remote_candidate(&mut self, cid: TId, candidate: Candidate, now: Instant) {
        if let Some((agent, maybe_state, _)) = self.connections.agent_and_state_mut(cid) {
            agent.invalidate_candidate(&candidate);
            agent.handle_timeout(now); // We may have invalidated the last candidate, ensure we check our nomination state.

            if let Some(state) = maybe_state {
                state.on_candidate(cid, agent, now);
            }
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
        cid: TId,
        packet: &IpPacket,
        now: Instant,
    ) -> Result<Option<Transmit>> {
        let conn = self.connections.get_established_mut(&cid, now)?;

        if matches!(self.role.kind(), RoleKind::Server) && !conn.state.has_nominated_socket() {
            tracing::debug!(
                ?packet,
                "ICE is still in progress; dropping packet because server should not initiate WireGuard sessions"
            );

            return Ok(None);
        }

        let socket = match &mut conn.state {
            ConnectionState::Connecting { ip_buffer, .. } => {
                ip_buffer.enqueue(packet.clone());
                let num_buffered = ip_buffer.len();

                tracing::debug!(%num_buffered, %cid, "ICE is still in progress, buffering IP packet");

                return Ok(None);
            }
            ConnectionState::Connected { peer_socket, .. } => *peer_socket,
            ConnectionState::Idle { peer_socket } => *peer_socket,
            ConnectionState::Failed => {
                return Err(anyhow!("Connection {cid} failed"));
            }
        };

        let maybe_transmit = conn
            .encapsulate(cid, socket, packet, now, &mut self.allocations)
            .with_context(|| format!("cid={cid}"))?;

        Ok(maybe_transmit)
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

        for (id, connection) in self.connections.iter_established_mut() {
            connection.handle_timeout(id, now, &mut self.allocations, &mut self.buffered_transmits);
        }

        for (id, connection) in self.connections.iter_initial_mut() {
            connection.handle_timeout(id, now);
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

        self.allocations.gc();
        self.connections.check_relays_available(
            &self.allocations,
            &mut self.pending_events,
            &mut self.rng,
            now,
        );
        self.connections
            .handle_timeout(&mut self.pending_events, now);
    }

    /// Returns buffered data that needs to be sent on the socket.
    #[must_use]
    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        if let Some(transmit) = self.allocations.poll_transmit() {
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
            let Some(allocation) = self.allocations.remove_by_id(rid) else {
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

            match self.allocations.upsert(
                *rid,
                *server,
                username,
                password.clone(),
                realm,
                now,
                self.session_id.clone(),
            ) {
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
    }

    #[must_use]
    fn init_connection(
        &mut self,
        cid: TId,
        mut agent: IceAgent,
        remote: PublicKey,
        key: x25519::StaticSecret,
        relay: RId,
        index: Index,
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
        // that even if the hole-punch was successful, it will take at most 15s
        // until we have a WireGuard tunnel to send packets into.
        tunnel.set_rekey_attempt_time(Duration::from_secs(15));

        Connection {
            agent,
            index,
            tunnel,
            next_wg_timer_update: now,
            stats: Default::default(),
            buffer: vec![0; ip_packet::MAX_FZ_PAYLOAD],
            intent_sent_at,
            signalling_completed_at: now,
            remote_pub_key: remote,
            relay: SelectedRelay {
                id: relay,
                logged_sample_failure: false,
            },
            state: ConnectionState::Connecting {
                wg_buffer: AllocRingBuffer::new(128),
                ip_buffer: AllocRingBuffer::new(128),
            },
            disconnected_at: None,
            buffer_pool: self.buffer_pool.clone(),
            last_proactive_handshake_sent_at: None,
            first_handshake_completed_at: None,
        }
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

        for (_, agent) in self.connections.agents_mut() {
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

        tracing::trace!("Packet was a STUN message but no agent handled it. Already disconnected?");

        ControlFlow::Break(Ok(()))
    }

    fn connections_try_handle(
        &mut self,
        from: SocketAddr,
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
            from.ip(),
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

            self.pending_events
                .push_back(Event::ConnectionEstablished(cid))
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
                    for (cid, agent, maybe_state) in
                        self.connections.agents_and_state_by_relay_mut(rid)
                    {
                        if let Some(candidate) = add_local_candidate(agent, candidate.clone()) {
                            self.pending_events
                                .push_back(new_ice_candidate_event(cid, candidate));
                        }

                        if let Some(state) = maybe_state {
                            state.on_candidate(cid, agent, now);
                        }
                    }
                }
                allocation::Event::Invalid(candidate) => {
                    for (cid, agent) in self.connections.agents_mut() {
                        remove_local_candidate(cid, agent, &candidate, &mut self.pending_events);
                    }
                }
            }
        }
    }

    /// Sample a relay to use for a new connection.
    fn sample_relay(&mut self) -> Result<RId, NoTurnServers> {
        let (rid, _) = self
            .allocations
            .sample(&mut self.rng)
            .ok_or(NoTurnServers {})?;

        tracing::debug!(%rid, "Sampled relay");

        Ok(rid)
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
    #[deprecated]
    #[expect(deprecated)]
    pub fn new_connection(
        &mut self,
        cid: TId,
        intent_sent_at: Instant,
        now: Instant,
    ) -> Result<Offer, NoTurnServers> {
        if self.connections.remove_initial(&cid).is_some() {
            tracing::info!("Replacing existing initial connection");
        };

        if self.connections.remove_established(&cid, now).is_some() {
            tracing::info!("Replacing existing established connection");
        };

        let agent = new_client_agent();

        let session_key = x25519::StaticSecret::random_from_rng(rand::thread_rng());
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
            relay: self.sample_relay()?,
            is_failed: false,
        };
        let duration_since_intent = initial_connection.duration_since_intent(now);

        let existing = self.connections.insert_initial(cid, initial_connection);
        debug_assert!(existing.is_none());

        tracing::info!(?duration_since_intent, "Establishing new connection");

        Ok(params)
    }

    /// Accept an [`Answer`] from the remote for a connection previously created via [`Node::new_connection`].
    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    #[deprecated]
    #[expect(deprecated)]
    pub fn accept_answer(&mut self, cid: TId, remote: PublicKey, answer: Answer, now: Instant) {
        let Some(initial) = self.connections.remove_initial(&cid) else {
            tracing::debug!("No initial connection state, ignoring answer"); // This can happen if the connection setup timed out.
            return;
        };

        let mut agent = initial.agent;
        agent.set_remote_credentials(IceCreds {
            ufrag: answer.credentials.username,
            pass: answer.credentials.password,
        });

        let selected_relay = initial.relay;

        for candidate in
            seed_agent_with_local_candidates(selected_relay, &mut agent, &self.allocations)
        {
            self.pending_events
                .push_back(new_ice_candidate_event(cid, candidate));
        }

        let index = self.index.next();
        let connection = self.init_connection(
            cid,
            agent,
            remote,
            initial.session_key,
            selected_relay,
            index,
            initial.intent_sent_at,
            now,
        );
        let duration_since_intent = connection.duration_since_intent(now);

        let existing = self.connections.insert_established(cid, index, connection);

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
    #[deprecated]
    #[expect(deprecated)]
    pub fn accept_connection(
        &mut self,
        cid: TId,
        offer: Offer,
        remote: PublicKey,
        now: Instant,
    ) -> Result<Answer, NoTurnServers> {
        debug_assert!(
            !self.connections.contains_initial(&cid),
            "server to not use `initial_connections`"
        );

        if self.connections.remove_established(&cid, now).is_some() {
            tracing::info!("Replacing existing established connection");
        };

        let mut agent = new_server_agent();
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

        let selected_relay = self.sample_relay()?;

        for candidate in
            seed_agent_with_local_candidates(selected_relay, &mut agent, &self.allocations)
        {
            self.pending_events
                .push_back(new_ice_candidate_event(cid, candidate));
        }

        let index = self.index.next();
        let connection = self.init_connection(
            cid,
            agent,
            remote,
            offer.session_key,
            selected_relay,
            index,
            now, // Technically, this isn't fully correct because gateways don't send intents so we just use the current time.
            now,
        );
        let existing = self.connections.insert_established(cid, index, connection);

        debug_assert!(existing.is_none());

        tracing::info!("Created new connection");

        Ok(answer)
    }
}

/// Seeds the agent with all local candidates, returning an iterator of all candidates that should be signalled to the remote.
fn seed_agent_with_local_candidates<'a, RId>(
    selected_relay: RId,
    agent: &'a mut IceAgent,
    allocations: &Allocations<RId>,
) -> impl Iterator<Item = Candidate> + use<'a, RId>
where
    RId: Ord + fmt::Display + Copy,
{
    allocations
        .candidates_for_relay(&selected_relay)
        .filter_map(move |c| add_local_candidate(agent, c))
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
fn generate_optimistic_candidates(agent: &mut IceAgent) {
    let remote_candidates = agent.remote_candidates();

    let public_ips = remote_candidates
        .iter()
        .filter_map(|c| (c.kind() == CandidateKind::ServerReflexive).then_some(c.addr().ip()));

    let host_candidates = remote_candidates
        .iter()
        .filter_map(|c| (c.kind() == CandidateKind::Host).then_some(c.addr()));

    let optimistic_candidates = public_ips
        .cartesian_product(host_candidates)
        .filter(|(ip, base)| ip.is_ipv4() && base.is_ipv4())
        .filter_map(|(ip, base)| {
            let addr = SocketAddr::new(ip, base.port());

            Candidate::server_reflexive(addr, base, Protocol::Udp)
                .inspect_err(
                    |e| tracing::debug!(%addr, %base, "Failed to create optimistic candidate: {e}"),
                )
                .ok()
        })
        .filter(|c| !remote_candidates.contains(c))
        .take(2)
        .collect::<Vec<_>>();

    for c in optimistic_candidates {
        tracing::debug!(candidate = ?c, "Adding optimistic candidate for remote");

        agent.add_remote_candidate(c);
    }
}

/// Attempts to add the candidate to the agent, returning back the candidate if it should be signalled to the remote.
fn add_local_candidate(agent: &mut IceAgent, candidate: Candidate) -> Option<Candidate> {
    // srflx candidates don't need to be added to the local agent because we always send from the `base` anyway.
    if candidate.kind() == CandidateKind::ServerReflexive {
        return Some(candidate);
    }

    let candidate = agent.add_local_candidate(candidate)?;

    Some(candidate.clone())
}

fn new_ice_candidate_event<TId>(id: TId, candidate: Candidate) -> Event<TId> {
    tracing::debug!(?candidate, "Signalling candidate to remote");

    Event::NewIceCandidate {
        connection: id,
        candidate,
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
    for (cid, agent) in connections.agents_mut() {
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
        pending_events.push_back(Event::InvalidateIceCandidate {
            connection: id,
            candidate: candidate.clone(),
        });
        return;
    }

    let was_present = agent.invalidate_candidate(candidate);

    if was_present {
        pending_events.push_back(Event::InvalidateIceCandidate {
            connection: id,
            candidate: candidate.clone(),
        })
    }
}

#[deprecated]
pub struct Offer {
    /// The Wireguard session key for a connection.
    pub session_key: x25519::StaticSecret,
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

#[cfg(test)]
impl From<str0m::IceCreds> for Credentials {
    fn from(value: str0m::IceCreds) -> Self {
        Credentials {
            username: value.ufrag,
            password: value.pass,
        }
    }
}

#[derive(Debug, PartialEq, Clone)]
pub enum Event<TId> {
    /// We created a new candidate for this connection and ask to signal it to the remote party.
    NewIceCandidate {
        connection: TId,
        candidate: Candidate,
    },

    /// We invalidated a candidate for this connection and ask to signal that to the remote party.
    InvalidateIceCandidate {
        connection: TId,
        candidate: Candidate,
    },

    ConnectionEstablished(TId),

    /// We failed to establish a connection.
    ///
    /// All state associated with the connection has been cleared.
    ConnectionFailed(TId),

    /// We closed a connection (e.g. due to inactivity, roaming, etc).
    ConnectionClosed(TId),
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

struct InitialConnection<RId> {
    agent: IceAgent,
    session_key: x25519::StaticSecret,

    /// The fallback relay we sampled for this potential connection.
    relay: RId,

    created_at: Instant,
    intent_sent_at: Instant,

    is_failed: bool,
}

impl<RId> InitialConnection<RId> {
    fn handle_timeout<TId>(&mut self, cid: TId, now: Instant)
    where
        TId: fmt::Display,
    {
        self.agent.handle_timeout(now);

        if now >= self.no_answer_received_timeout() {
            tracing::info!(%cid, "Connection setup timed out (no answer received)");
            self.is_failed = true;
        }
    }

    fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            .chain(
                self.agent
                    .poll_timeout()
                    .map(|timeout| (timeout, "ICE agent")),
            )
            .chain(Some((
                self.no_answer_received_timeout(),
                "connection handshake timeout",
            )))
            .min_by_key(|(instant, _)| *instant)
    }

    fn no_answer_received_timeout(&self) -> Instant {
        self.created_at + HANDSHAKE_TIMEOUT
    }

    fn duration_since_intent(&self, now: Instant) -> Duration {
        now.duration_since(self.intent_sent_at)
    }
}

#[derive(derive_more::Debug)]
struct Connection<RId> {
    agent: IceAgent,

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
    signalling_completed_at: Instant,
    first_handshake_completed_at: Option<Instant>,

    buffer: Vec<u8>,

    #[debug(skip)]
    buffer_pool: BufferPool<Vec<u8>>,
}

#[derive(Debug)]
struct SelectedRelay<RId> {
    id: RId,
    /// Whether we've already logged failure to sample a new relay.
    logged_sample_failure: bool,
}

#[derive(Debug)]
enum ConnectionState {
    /// We are still running ICE to figure out, which socket to use to send data.
    Connecting {
        /// Packets emitted by wireguard whilst are still running ICE.
        ///
        /// This can happen if the remote's WG session initiation arrives at our socket before we nominate it.
        /// A session initiation requires a response that we must not drop, otherwise the connection setup experiences unnecessary delays.
        wg_buffer: AllocRingBuffer<Vec<u8>>,

        /// Packets we are told to send whilst we are still running ICE.
        ///
        /// These need to be encrypted and sent once the tunnel is established.
        ip_buffer: AllocRingBuffer<IpPacket>,
    },
    /// A socket has been nominated.
    Connected {
        /// Our nominated socket.
        peer_socket: PeerSocket,

        last_activity: Instant,
    },
    /// We haven't seen application packets in a while.
    Idle {
        /// Our nominated socket.
        peer_socket: PeerSocket,
    },
    /// The connection failed in an unrecoverable way and will be GC'd.
    Failed,
}

impl ConnectionState {
    fn poll_timeout(&self, agent: &IceAgent) -> Option<(Instant, &'static str)> {
        if agent.state() != IceConnectionState::Connected {
            return None;
        }

        match self {
            ConnectionState::Connected { last_activity, .. } => {
                Some((idle_at(*last_activity), "idle transition"))
            }
            ConnectionState::Connecting { .. }
            | ConnectionState::Idle { .. }
            | ConnectionState::Failed => None,
        }
    }

    fn handle_timeout(&mut self, agent: &mut IceAgent, now: Instant) {
        let Self::Connected {
            last_activity,
            peer_socket,
        } = self
        else {
            return;
        };

        if idle_at(*last_activity) > now {
            return;
        }

        if agent.state() != IceConnectionState::Connected {
            return;
        }

        let peer_socket = *peer_socket;

        self.transition_to_idle(peer_socket, agent);
    }

    fn on_upsert<TId>(&mut self, cid: TId, agent: &mut IceAgent, now: Instant)
    where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(cid, peer_socket, agent, "upsert", now);
    }

    fn on_candidate<TId>(&mut self, cid: TId, agent: &mut IceAgent, now: Instant)
    where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(cid, peer_socket, agent, "candidates changed", now);
    }

    fn on_outgoing<TId>(&mut self, cid: TId, agent: &mut IceAgent, packet: &IpPacket, now: Instant)
    where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(cid, peer_socket, agent, tracing::field::debug(packet), now);
    }

    fn on_incoming<TId>(&mut self, cid: TId, agent: &mut IceAgent, packet: &IpPacket, now: Instant)
    where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(cid, peer_socket, agent, tracing::field::debug(packet), now);
    }

    fn transition_to_idle(&mut self, peer_socket: PeerSocket, agent: &mut IceAgent) {
        tracing::debug!("Connection is idle");
        *self = Self::Idle { peer_socket };
        apply_idle_stun_timings(agent);
    }

    fn transition_to_connected<TId>(
        &mut self,
        cid: TId,
        peer_socket: PeerSocket,
        agent: &mut IceAgent,
        trigger: impl tracing::Value,
        now: Instant,
    ) where
        TId: fmt::Display,
    {
        tracing::debug!(trigger, %cid, "Connection resumed");
        *self = Self::Connected {
            peer_socket,
            last_activity: now,
        };
        apply_default_stun_timings(agent);
    }

    fn has_nominated_socket(&self) -> bool {
        matches!(self, Self::Connected { .. } | Self::Idle { .. })
    }
}

impl fmt::Display for ConnectionState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectionState::Connecting { .. } => write!(f, "Connecting"),
            ConnectionState::Connected { peer_socket, .. } => {
                write!(f, "Connected({})", peer_socket.kind())
            }
            ConnectionState::Idle { peer_socket } => write!(f, "Idle({})", peer_socket.kind()),
            ConnectionState::Failed => write!(f, "Failed"),
        }
    }
}

fn idle_at(last_activity: Instant) -> Instant {
    const MAX_IDLE: Duration = Duration::from_secs(20); // Must be longer than the ICE timeout otherwise we might not detect a failed connection early enough.

    last_activity + MAX_IDLE
}

/// The socket of the peer we are connected to.
#[derive(PartialEq, Clone, Copy, Debug)]
enum PeerSocket {
    PeerToPeer {
        source: SocketAddr,
        dest: SocketAddr,
    },
    PeerToRelay {
        source: SocketAddr,
        dest: SocketAddr,
    },
    RelayToPeer {
        dest: SocketAddr,
    },
    RelayToRelay {
        dest: SocketAddr,
    },
}

impl PeerSocket {
    fn send_from_relay(&self) -> bool {
        matches!(self, Self::RelayToPeer { .. } | Self::RelayToRelay { .. })
    }

    fn fmt<RId>(&self, relay: RId) -> String
    where
        RId: fmt::Display,
    {
        match self {
            PeerSocket::PeerToPeer { source, dest } => {
                format!("PeerToPeer {{ source: {source}, dest: {dest} }}")
            }
            PeerSocket::PeerToRelay { source, dest } => {
                format!("PeerToRelay {{ source: {source}, dest: {dest} }}")
            }
            PeerSocket::RelayToPeer { dest } => {
                format!("RelayToPeer {{ relay: {relay}, dest: {dest} }}")
            }
            PeerSocket::RelayToRelay { dest } => {
                format!("RelayToRelay {{ relay: {relay}, dest: {dest} }}")
            }
        }
    }

    fn kind(&self) -> &'static str {
        match self {
            PeerSocket::PeerToPeer { .. } => "PeerToPeer",
            PeerSocket::PeerToRelay { .. } => "PeerToRelay",
            PeerSocket::RelayToPeer { .. } => "RelayToPeer",
            PeerSocket::RelayToRelay { .. } => "RelayToRelay",
        }
    }
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
        iter::empty()
            .chain(
                self.agent
                    .poll_timeout()
                    .map(|instant| (instant, "ICE agent")),
            )
            .chain(Some((self.next_wg_timer_update, "boringtun tunnel")))
            .chain(
                self.candidate_timeout()
                    .map(|instant| (instant, "candidate timeout")),
            )
            .chain(
                self.disconnect_timeout()
                    .map(|instant| (instant, "disconnect timeout")),
            )
            .chain(self.state.poll_timeout(&self.agent))
            .min_by_key(|(instant, _)| *instant)
    }

    fn candidate_timeout(&self) -> Option<Instant> {
        if !self.agent.remote_candidates().is_empty() {
            return None;
        }

        Some(self.signalling_completed_at + CANDIDATE_TIMEOUT)
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
        transmits: &mut VecDeque<Transmit>,
    ) where
        TId: Copy + Ord + fmt::Display,
        RId: Copy + Ord + fmt::Display,
    {
        let _guard = tracing::info_span!("handle_timeout", %cid).entered();

        self.agent.handle_timeout(now);
        self.state.handle_timeout(&mut self.agent, now);

        if self
            .candidate_timeout()
            .is_some_and(|timeout| now >= timeout)
        {
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

        while let Some(event) = self.agent.poll_event() {
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
                    let source_relay = allocations.get_mut_by_allocation(source).map(|(r, _)| r);

                    if source_relay.is_some_and(|r| self.relay.id != r) {
                        tracing::warn!(
                            "Nominated a relay different from what we set out to! Weird?"
                        );
                    }

                    let dest_is_relay = self
                        .agent
                        .remote_candidates()
                        .iter()
                        .any(|c| c.addr() == destination && c.kind() == CandidateKind::Relayed);

                    let remote_socket = match (source_relay, dest_is_relay) {
                        (None, false) => PeerSocket::PeerToPeer {
                            source,
                            dest: destination,
                        },
                        (None, true) => PeerSocket::PeerToRelay {
                            source,
                            dest: destination,
                        },
                        (Some(_), false) => PeerSocket::RelayToPeer { dest: destination },
                        (Some(_), true) => PeerSocket::RelayToRelay { dest: destination },
                    };

                    let old = match mem::replace(&mut self.state, ConnectionState::Failed) {
                        ConnectionState::Connecting {
                            wg_buffer,
                            ip_buffer,
                            ..
                        } => {
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

                            tracing::debug!(
                                num_buffered = %ip_buffer.len(),
                                "Flushing IP packets buffered during ICE"
                            );
                            transmits.extend(ip_buffer.into_iter().flat_map(|packet| {
                                let transmit = self
                                    .encapsulate(cid, remote_socket, &packet, now, allocations)
                                    .inspect_err(|e| {
                                        tracing::debug!(
                                            "Failed to encapsulate buffered IP packet: {e:#}"
                                        )
                                    })
                                    .ok()??;

                                Some(transmit)
                            }));

                            self.state = ConnectionState::Connected {
                                peer_socket: remote_socket,
                                last_activity: now,
                            };
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

                    if self.agent.controlling() {
                        self.initiate_wg_session(allocations, transmits, now);
                    }
                }
                IceAgentEvent::IceRestart(_) | IceAgentEvent::IceConnectionStateChange(_) => {}
            }
        }

        while let Some(transmit) = self.agent.poll_transmit() {
            let source = transmit.source;
            let dst = transmit.destination;
            let stun_packet = transmit.contents;

            // Check if `str0m` wants us to send from a "remote" socket, i.e. one that we allocated with a relay.
            let Some((relay, allocation)) = allocations.get_mut_by_allocation(source) else {
                self.stats.stun_bytes_to_peer_direct += stun_packet.len();

                // `source` did not match any of our allocated sockets, must be a local one then!
                transmits.push_back(Transmit {
                    src: Some(source),
                    dst,
                    payload: self.buffer_pool.pull_initialised(&Vec::from(stun_packet)),
                    ecn: Ecn::NonEct,
                });
                continue;
            };

            let mut data_channel_packet = channel_data_packet_buffer(&stun_packet);

            // Payload should be sent from a "remote socket", let's wrap it in a channel data message!
            let Some(encode_ok) =
                allocation.encode_channel_data_header(dst, &mut data_channel_packet, now)
            else {
                // Unlikely edge-case, drop the packet and continue.
                tracing::trace!(%relay, peer = %dst, "Dropping packet because allocation does not offer a channel to peer");
                continue;
            };

            self.stats.stun_bytes_to_peer_relayed += data_channel_packet.len();

            transmits.push_back(Transmit {
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
        transmits: &mut VecDeque<Transmit>,
    ) {
        // Don't update wireguard timers until we are connected.
        let Some(peer_socket) = self.socket() else {
            return;
        };

        /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
        ///
        /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
        const MAX_SCRATCH_SPACE: usize = 148;

        let mut buf = [0u8; MAX_SCRATCH_SPACE];

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
                transmits.extend(make_owned_transmit(
                    self.relay.id,
                    peer_socket,
                    b,
                    &self.buffer_pool,
                    allocations,
                    now,
                ));
            }
            TunnResult::WriteToTunnelV4(..) | TunnResult::WriteToTunnelV6(..) => {
                panic!("Unexpected result from update_timers")
            }
        };
    }

    fn encapsulate<TId>(
        &mut self,
        cid: TId,
        socket: PeerSocket,
        packet: &IpPacket,
        now: Instant,
        allocations: &mut Allocations<RId>,
    ) -> Result<Option<Transmit>>
    where
        TId: fmt::Display,
    {
        self.state.on_outgoing(cid, &mut self.agent, packet, now);

        let packet_start = if socket.send_from_relay() { 4 } else { 0 };

        let mut buffer = self.buffer_pool.pull();
        buffer.resize(ip_packet::MAX_FZ_PAYLOAD, 0);

        let len =
            match self
                .tunnel
                .encapsulate_at(packet.packet(), &mut buffer[packet_start..], now)
            {
                TunnResult::Done => return Ok(None),
                TunnResult::Err(e) => return Err(anyhow::Error::new(e)),
                TunnResult::WriteToNetwork(packet) => packet.len(),
                TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                    unreachable!("never returned from encapsulate")
                }
            };

        let packet_end = packet_start + len;
        buffer.truncate(packet_end);

        match socket {
            PeerSocket::PeerToPeer {
                source,
                dest: remote,
            }
            | PeerSocket::PeerToRelay {
                source,
                dest: remote,
            } => Ok(Some(Transmit {
                src: Some(source),
                dst: remote,
                payload: buffer,
                ecn: packet.ecn(),
            })),
            PeerSocket::RelayToPeer { dest: peer } | PeerSocket::RelayToRelay { dest: peer } => {
                let Some(allocation) = allocations.get_mut_by_id(&self.relay.id) else {
                    tracing::warn!(relay = %self.relay.id, "No allocation");
                    return Ok(None);
                };
                let Some(encode_ok) =
                    allocation.encode_channel_data_header(peer, &mut buffer[..packet_end], now)
                else {
                    return Ok(None);
                };

                buffer.truncate(packet_end);

                Ok(Some(Transmit {
                    src: None,
                    dst: encode_ok.socket,
                    payload: buffer,
                    ecn: packet.ecn(),
                }))
            }
        }
    }

    fn decapsulate<TId>(
        &mut self,
        cid: TId,
        src: IpAddr,
        packet: &[u8],
        allocations: &mut Allocations<RId>,
        transmits: &mut VecDeque<Transmit>,
        now: Instant,
    ) -> ControlFlow<Result<()>, IpPacket>
    where
        TId: fmt::Display,
    {
        let mut ip_packet = IpPacketBuf::new();

        let control_flow = match self
            .tunnel
            .decapsulate_at(Some(src), packet, ip_packet.buf(), now)
        {
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

        if let ControlFlow::Continue(packet) = &control_flow {
            self.state.on_incoming(cid, &mut self.agent, packet, now);
        }

        control_flow
    }

    fn initiate_wg_session(
        &mut self,
        allocations: &mut Allocations<RId>,
        transmits: &mut VecDeque<Transmit>,
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

        transmits.extend(make_owned_transmit(
            self.relay.id,
            socket,
            bytes,
            &self.buffer_pool,
            allocations,
            now,
        ));
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

fn new_client_agent() -> IceAgent {
    let mut agent = IceAgent::new();
    agent.set_controlling(true);
    agent.set_timing_advance(Duration::ZERO);

    apply_default_stun_timings(&mut agent);

    agent
}

fn new_server_agent() -> IceAgent {
    let mut agent = IceAgent::new();
    agent.set_controlling(false);
    agent.set_timing_advance(Duration::ZERO);

    apply_default_stun_timings(&mut agent);

    agent
}

fn apply_default_stun_timings(agent: &mut IceAgent) {
    let retrans = if agent.controlling() { 12 } else { 45 };
    let max_stun_rto = if agent.controlling() { 1500 } else { 15_000 };

    agent.set_max_stun_retransmits(retrans);
    agent.set_max_stun_rto(Duration::from_millis(max_stun_rto));
    agent.set_initial_stun_rto(Duration::from_millis(250))
}

fn apply_idle_stun_timings(agent: &mut IceAgent) {
    let retrans = if agent.controlling() { 4 } else { 40 };

    agent.set_max_stun_retransmits(retrans);
    agent.set_max_stun_rto(Duration::from_secs(25));
    agent.set_initial_stun_rto(Duration::from_secs(25));
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

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};

    use super::*;

    #[test]
    fn client_default_ice_timeout() {
        let mut agent = new_client_agent();

        apply_default_stun_timings(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_millis(15250))
    }

    #[test]
    fn client_idle_ice_timeout() {
        let mut agent = new_client_agent();

        apply_idle_stun_timings(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_secs(100))
    }

    #[test]
    fn server_default_ice_timeout() {
        let mut agent = new_server_agent();

        apply_default_stun_timings(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_millis(600_750))
    }

    #[test]
    fn server_idle_ice_timeout() {
        let mut agent = new_server_agent();

        apply_idle_stun_timings(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_secs(1000))
    }

    #[test]
    fn generates_correct_optimistic_candidates() {
        let base = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 1), 52625));
        let addr = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1));

        let host = Candidate::host(base, "udp").unwrap();
        let srvflx =
            Candidate::server_reflexive(SocketAddr::new(addr, 40000), base, "udp").unwrap();

        let mut agent = IceAgent::new();
        agent.add_remote_candidate(host);
        agent.add_remote_candidate(srvflx);

        generate_optimistic_candidates(&mut agent);

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

        let mut agent = IceAgent::new();
        agent.add_remote_candidate(host);
        agent.add_remote_candidate(srvflx);

        generate_optimistic_candidates(&mut agent);

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

        let mut agent = IceAgent::new();
        agent.add_remote_candidate(host);
        agent.add_remote_candidate(srflx1);
        agent.add_remote_candidate(srflx2);
        agent.add_remote_candidate(srflx3);

        generate_optimistic_candidates(&mut agent);

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
