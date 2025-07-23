use crate::allocation::{self, Allocation, RelaySocket, Socket};
use crate::candidate_set::CandidateSet;
use crate::index::IndexLfsr;
use crate::stats::{ConnectionStats, NodeStats};
use crate::utils::channel_data_packet_buffer;
use anyhow::{Context, Result, anyhow};
use boringtun::noise::errors::WireGuardError;
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::PublicKey;
use boringtun::{noise::rate_limiter::RateLimiter, x25519::StaticSecret};
use bufferpool::{Buffer, BufferPool};
use core::fmt;
use firezone_logging::err_with_src;
use hex_display::HexDisplayExt;
use ip_packet::{ConvertibleIpv4Packet, ConvertibleIpv6Packet, IpPacket, IpPacketBuf};
use itertools::Itertools;
use rand::rngs::StdRng;
use rand::seq::IteratorRandom;
use rand::{Rng, RngCore, SeedableRng, random};
use ringbuffer::{AllocRingBuffer, RingBuffer as _};
use secrecy::{ExposeSecret, Secret};
use sha2::Digest;
use std::collections::btree_map::Entry;
use std::collections::{BTreeMap, BTreeSet};
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

trait Mode {
    fn new() -> Self;
    fn is_client(&self) -> bool;

    fn is_server(&self) -> bool {
        !self.is_client()
    }
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
    buffered_transmits: VecDeque<Transmit>,

    next_rate_limiter_reset: Option<Instant>,

    allocations: BTreeMap<RId, Allocation>,

    connections: Connections<TId, RId>,
    pending_events: VecDeque<Event<TId>>,

    stats: NodeStats,
    buffer_pool: BufferPool<Vec<u8>>,

    mode: T,
    rng: StdRng,
}

#[derive(thiserror::Error, Debug)]
#[error("No TURN servers available")]
pub struct NoTurnServers {}

#[expect(private_bounds, reason = "We don't want `Mode` to be public API")]
impl<T, TId, RId> Node<T, TId, RId>
where
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
    T: Mode,
{
    pub fn new(seed: [u8; 32], now: Instant) -> Self {
        let mut rng = StdRng::from_seed(seed);
        let private_key = StaticSecret::random_from_rng(&mut rng);
        let public_key = &(&private_key).into();
        let index = IndexLfsr::new(&mut rng);

        Self {
            rng,
            session_id: SessionId::new(*public_key),
            private_key,
            public_key: *public_key,
            mode: T::new(),
            index,
            rate_limiter: Arc::new(RateLimiter::new_at(public_key, HANDSHAKE_RATE_LIMIT, now)),
            shared_candidates: Default::default(),
            buffered_transmits: VecDeque::default(),
            next_rate_limiter_reset: None,
            pending_events: VecDeque::default(),
            allocations: Default::default(),
            connections: Default::default(),
            stats: Default::default(),
            buffer_pool: BufferPool::new(ip_packet::MAX_FZ_PAYLOAD, "snownet"),
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

        self.shared_candidates.clear();
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
        session_key: Secret<[u8; 32]>,
        local_creds: Credentials,
        remote_creds: Credentials,
        now: Instant,
    ) -> Result<(), NoTurnServers> {
        let local_creds = local_creds.into();
        let remote_creds = remote_creds.into();

        if self.connections.initial.contains_key(&cid) {
            debug_assert!(
                false,
                "The new `upsert_connection` API is incompatible with the previous `new_connection` API"
            );
            return Ok(());
        }

        // Compare the ICE credentials and public key.
        // Technically, just comparing the ICE credentials should be enough because the portal computes them deterministically based on Client/Gateway ID and their public keys.
        // But better be safe than sorry.
        if let Some(c) = self.connections.get_established_mut(&cid)
            && c.agent.local_credentials() == &local_creds
            && c.agent
                .remote_credentials()
                .is_some_and(|c| c == &remote_creds)
            && c.tunnel.remote_static_public() == remote
        {
            c.state.on_upsert(cid, &mut c.agent, now);

            tracing::info!(local = ?local_creds, "Reusing existing connection");
            return Ok(());
        }

        let existing = self.connections.established.remove(&cid);

        if let Some(existing) = existing {
            let current_local = existing.agent.local_credentials();
            tracing::info!(?current_local, new_local = ?local_creds, remote = ?remote_creds, "Replacing existing connection");
        } else {
            tracing::info!(local = ?local_creds, remote = ?remote_creds, "Creating new connection");
        }

        let selected_relay = self.sample_relay()?;

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

        self.connections.established.insert(cid, connection);

        Ok(())
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
    pub fn add_local_host_candidate(&mut self, address: SocketAddr) -> Result<()> {
        self.add_local_as_host_candidate(address)?;

        Ok(())
    }

    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn add_remote_candidate(&mut self, cid: TId, candidate: String, now: Instant) {
        let candidate = match Candidate::from_sdp_string(&candidate) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!("Failed to parse candidate: {}", err_with_src(&e));
                return;
            }
        };

        let Some((agent, relay)) = self.connections.connecting_agent_mut(cid) else {
            tracing::debug!(ignored_candidate = %candidate, "Unknown connection or socket has already been nominated");
            return;
        };

        tracing::info!(?candidate, "Received candidate from remote");

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

        let Some(allocation) = relay.and_then(|r| self.allocations.get_mut(&r)) else {
            tracing::debug!(rid = ?relay, "Unknown relay");
            return;
        };

        allocation.bind_channel(candidate.addr(), now);
    }

    #[tracing::instrument(level = "info", skip_all, fields(%cid))]
    pub fn remove_remote_candidate(&mut self, cid: TId, candidate: String, now: Instant) {
        let candidate = match Candidate::from_sdp_string(&candidate) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!("Failed to parse candidate: {}", err_with_src(&e));
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
    ) -> Result<Option<(TId, IpPacket)>> {
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
        cid: TId,
        packet: IpPacket,
        now: Instant,
    ) -> Result<Option<Transmit>> {
        let conn = self
            .connections
            .get_established_mut(&cid)
            .with_context(|| format!("Unknown connection {cid}"))?;

        if self.mode.is_server() && !conn.state.has_nominated_socket() {
            tracing::debug!(
                ?packet,
                "ICE is still in progress; dropping packet because server should not initiate WireGuard sessions"
            );

            return Ok(None);
        }

        let socket = match &mut conn.state {
            ConnectionState::Connecting { ip_buffer, .. } => {
                ip_buffer.push(packet);
                let num_buffered = ip_buffer.len();

                tracing::debug!(%num_buffered, %cid, "ICE is still in progress, buffering WG handshake");

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
            .chain(
                self.allocations
                    .values_mut()
                    .filter_map(|a| a.poll_timeout()),
            )
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
                self.rate_limiter.reset_count_at(now);
                self.next_rate_limiter_reset = Some(now + Duration::from_secs(1));
            }
        }

        self.allocations
            .retain(|rid, allocation| match allocation.can_be_freed() {
                Some(e) => {
                    tracing::info!(%rid, "Disconnecting from relay; {e}");

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
    pub fn poll_transmit(&mut self) -> Option<Transmit> {
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
                        self.buffer_pool.clone(),
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
                        self.buffer_pool.clone(),
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
        relay: RId,
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
            self.index.next(),
            Some(self.rate_limiter.clone()),
            self.rng.next_u64(),
            now,
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
            tunnel,
            next_wg_timer_update: now,
            stats: Default::default(),
            buffer: vec![0; ip_packet::MAX_FZ_PAYLOAD],
            intent_sent_at,
            signalling_completed_at: now,
            remote_pub_key: remote,
            state: ConnectionState::Connecting {
                relay: Some(relay),
                wg_buffer: AllocRingBuffer::new(128),
                ip_buffer: AllocRingBuffer::new(128),
            },
            disconnected_at: None,
            possible_sockets: BTreeSet::default(),
            buffer_pool: self.buffer_pool.clone(),
        }
    }

    /// Attempt to add the `local` address as a host candidate.
    ///
    /// Receiving traffic on a certain interface means we at least have a connection to a relay via this interface.
    /// Thus, it is also a viable interface to attempt a connection to a gateway.
    fn add_local_as_host_candidate(&mut self, local: SocketAddr) -> Result<()> {
        let host_candidate =
            Candidate::host(local, Protocol::Udp).context("Failed to parse host candidate")?;

        if !self.shared_candidates.insert(host_candidate.clone()) {
            return Ok(());
        }

        for (cid, agent) in self.connections.agents_mut() {
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
                let Ok(cd) = crate::channel_data::decode(packet) else {
                    // False-positive, continue processing packet elsewhere
                    return ControlFlow::Continue((from, packet, None));
                };

                let Some(allocation) = self
                    .allocations
                    .values_mut()
                    .find(|a| a.server().matches(from))
                else {
                    tracing::debug!("Packet was a channel data message for unknown allocation");

                    return ControlFlow::Break(()); // Stop processing the packet.
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
        for (cid, conn) in self.connections.iter_established_mut() {
            if !conn.accepts(&from) {
                continue;
            }

            let handshake_complete_before_decapsulate = conn.wg_handshake_complete(now);

            let control_flow = conn.decapsulate(
                cid,
                from.ip(),
                packet,
                &mut self.allocations,
                &mut self.buffered_transmits,
                now,
            );

            let handshake_complete_after_decapsulate = conn.wg_handshake_complete(now);

            // I can't think of a better way to detect this ...
            if !handshake_complete_before_decapsulate && handshake_complete_after_decapsulate {
                tracing::info!(%cid, duration_since_intent = ?conn.duration_since_intent(now), "Completed wireguard handshake");

                self.pending_events
                    .push_back(Event::ConnectionEstablished(cid))
            }

            return match control_flow {
                ControlFlow::Continue(c) => ControlFlow::Continue((cid, c)),
                ControlFlow::Break(b) => ControlFlow::Break(
                    b.with_context(|| format!("cid={cid} length={}", packet.len())),
                ),
            };
        }

        if crate::is_wireguard(packet) {
            tracing::trace!(
                "Packet was a WireGuard packet but no connection handled it. Already disconnected?"
            );

            return ControlFlow::Break(Ok(()));
        }

        tracing::debug!(packet = %hex::encode(packet));

        ControlFlow::Break(Err(anyhow!("Packet has unknown format")))
    }

    fn allocations_drain_events(&mut self) {
        let allocation_events = self.allocations.iter_mut().flat_map(|(rid, allocation)| {
            std::iter::from_fn(|| allocation.poll_event()).map(|e| (*rid, e))
        });

        for (rid, event) in allocation_events {
            tracing::trace!(%rid, ?event);

            match event {
                allocation::Event::New(candidate)
                    if candidate.kind() == CandidateKind::ServerReflexive =>
                {
                    if !self.shared_candidates.insert(candidate.clone()) {
                        continue;
                    }

                    for (cid, agent) in self.connections.connecting_agents_by_relay_mut(rid) {
                        add_local_candidate(cid, agent, candidate.clone(), &mut self.pending_events)
                    }
                }
                allocation::Event::New(candidate) => {
                    for (cid, agent) in self.connections.connecting_agents_by_relay_mut(rid) {
                        add_local_candidate(cid, agent, candidate.clone(), &mut self.pending_events)
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
        let rid = self
            .allocations
            .keys()
            .copied()
            .choose(&mut self.rng)
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
    #[must_use]
    #[deprecated]
    #[expect(deprecated)]
    pub fn new_connection(
        &mut self,
        cid: TId,
        intent_sent_at: Instant,
        now: Instant,
    ) -> Result<Offer, NoTurnServers> {
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
            relay: self.sample_relay()?,
            is_failed: false,
            span: tracing::Span::none(),
        };
        let duration_since_intent = initial_connection.duration_since_intent(now);

        let existing = self.connections.initial.insert(cid, initial_connection);
        debug_assert!(existing.is_none());

        tracing::info!(?duration_since_intent, "Establishing new connection");

        Ok(params)
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
    ) -> Result<Answer, NoTurnServers> {
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

        let selected_relay = self.sample_relay()?;
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

        Ok(answer)
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
        selected_relay: RId,
        agent: &mut IceAgent,
    ) {
        for candidate in self.shared_candidates.iter().cloned() {
            add_local_candidate(connection, agent, candidate, &mut self.pending_events);
        }

        let Some(allocation) = self.allocations.get(&selected_relay) else {
            tracing::debug!(%selected_relay, "Cannot seed relay candidates: Unknown relay");
            return;
        };

        for candidate in allocation.current_relay_candidates() {
            add_local_candidate(connection, agent, candidate, &mut self.pending_events);
        }
    }
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
        .filter(|(ip, base)| ip.is_ipv4() == base.is_ipv4())
        .filter_map(|(ip, base)| {
            let addr = SocketAddr::new(ip, base.port());

            Candidate::server_reflexive(addr, base, Protocol::Udp)
                .inspect_err(
                    |e| tracing::debug!(%addr, %base, "Failed to create optimistic candidate: {e}"),
                )
                .ok()
        })
        .filter(|c| !remote_candidates.contains(c))
        .collect::<Vec<_>>();

    for c in optimistic_candidates {
        tracing::info!(candidate = ?c, "Adding optimistic candidate for remote");

        agent.add_remote_candidate(c);
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
            if allocations.contains_key(&c.relay) {
                continue;
            }

            let _guard = c.span.enter();

            let Some(new_rid) = allocations.keys().copied().choose(rng) else {
                continue;
            };

            tracing::info!(old_rid = ?c.relay, %new_rid, "Updating relay");
            c.relay = new_rid;
        }

        // For established connections, we check if we are currently using the relay.
        for (_, c) in self.iter_established_mut() {
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
                PeerSocket::PeerToPeer { .. } | PeerSocket::PeerToRelay { .. } => continue, // Don't care if relay of direct connection disappears, we weren't using it anyway.
                PeerSocket::RelayToPeer { relay, .. } | PeerSocket::RelayToRelay { relay, .. } => {
                    relay
                }
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
        let maybe_initial_connection = self
            .initial
            .get_mut(&id)
            .map(|i| (&mut i.agent, Some(i.relay)));
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
    ) -> impl Iterator<Item = (TId, &mut IceAgent)> + '_ {
        let initial_connections = self
            .initial
            .iter_mut()
            .filter_map(move |(cid, i)| (i.relay == id).then_some((*cid, &mut i.agent)));
        let pending_connections = self.established.iter_mut().filter_map(move |(cid, c)| {
            use ConnectionState::*;

            match c.state {
                Connecting {
                    relay: Some(relay), ..
                } if relay == id => Some((*cid, &mut c.agent)),
                Failed | Idle { .. } | Connecting { .. } | Connected { .. } => None,
            }
        });

        initial_connections.chain(pending_connections)
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

    fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            .chain(self.initial.values_mut().filter_map(|c| c.poll_timeout()))
            .chain(
                self.established
                    .values_mut()
                    .filter_map(|c| c.poll_timeout()),
            )
            .min_by_key(|(instant, _)| *instant)
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
    // srflx candidates don't need to be added to the local agent because we always send from the `base` anyway.
    if candidate.kind() == CandidateKind::ServerReflexive {
        tracing::info!(?candidate, "Signalling candidate to remote");

        pending_events.push_back(Event::NewIceCandidate {
            connection: id,
            candidate: candidate.to_sdp_string(),
        });
        return;
    }

    let Some(candidate) = agent.add_local_candidate(candidate) else {
        return;
    };

    tracing::info!(?candidate, "Signalling candidate to remote");

    pending_events.push_back(Event::NewIceCandidate {
        connection: id,
        candidate: candidate.to_sdp_string(),
    })
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
    session_key: Secret<[u8; 32]>,

    /// The fallback relay we sampled for this potential connection.
    relay: RId,

    created_at: Instant,
    intent_sent_at: Instant,

    is_failed: bool,

    span: tracing::Span,
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

struct Connection<RId> {
    agent: IceAgent,

    tunnel: Tunn,
    remote_pub_key: PublicKey,
    /// When to next update the [`Tunn`]'s timers.
    next_wg_timer_update: Instant,

    state: ConnectionState<RId>,
    disconnected_at: Option<Instant>,

    /// Socket addresses from which we might receive data (even before we are connected).
    possible_sockets: BTreeSet<SocketAddr>,

    stats: ConnectionStats,
    intent_sent_at: Instant,
    signalling_completed_at: Instant,

    buffer: Vec<u8>,

    buffer_pool: BufferPool<Vec<u8>>,
}

enum ConnectionState<RId> {
    /// We are still running ICE to figure out, which socket to use to send data.
    Connecting {
        /// The relay we have selected for this connection.
        relay: Option<RId>,

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
    fn poll_timeout(&self) -> Option<(Instant, &'static str)> {
        match self {
            ConnectionState::Connected {
                last_incoming,
                last_outgoing,
                ..
            } => Some((idle_at(*last_incoming, *last_outgoing), "idle transition")),
            ConnectionState::Connecting { .. }
            | ConnectionState::Idle { .. }
            | ConnectionState::Failed => None,
        }
    }

    fn handle_timeout<TId>(&mut self, cid: TId, agent: &mut IceAgent, now: Instant)
    where
        TId: fmt::Display,
    {
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

        self.transition_to_idle(cid, peer_socket, agent);
    }

    fn on_upsert<TId>(&mut self, cid: TId, agent: &mut IceAgent, now: Instant)
    where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Failed | Self::Connecting { .. } | Self::Connected { .. } => return,
        };

        self.transition_to_connected(cid, peer_socket, agent, "upsert", now);
    }

    fn on_outgoing<TId>(&mut self, cid: TId, agent: &mut IceAgent, packet: &IpPacket, now: Instant)
    where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_outgoing, .. } => {
                *last_outgoing = now;
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
            Self::Connected { last_incoming, .. } => {
                *last_incoming = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(cid, peer_socket, agent, tracing::field::debug(packet), now);
    }

    fn transition_to_idle<TId>(
        &mut self,
        cid: TId,
        peer_socket: PeerSocket<RId>,
        agent: &mut IceAgent,
    ) where
        TId: fmt::Display,
    {
        tracing::debug!(%cid, "Connection is idle");
        *self = Self::Idle { peer_socket };
        apply_idle_stun_timings(agent);
    }

    fn transition_to_connected<TId>(
        &mut self,
        cid: TId,
        peer_socket: PeerSocket<RId>,
        agent: &mut IceAgent,
        trigger: impl tracing::Value,
        now: Instant,
    ) where
        TId: fmt::Display,
    {
        tracing::debug!(trigger, %cid, "Connection resumed");
        *self = Self::Connected {
            peer_socket,
            last_outgoing: now,
            last_incoming: now,
        };
        apply_default_stun_timings(agent);
    }

    fn has_nominated_socket(&self) -> bool {
        matches!(self, Self::Connected { .. } | Self::Idle { .. })
    }
}

fn idle_at(last_incoming: Instant, last_outgoing: Instant) -> Instant {
    const MAX_IDLE: Duration = Duration::from_secs(20); // Must be longer than the ICE timeout otherwise we might not detect a failed connection early enough.

    last_incoming.max(last_outgoing) + MAX_IDLE
}

/// The socket of the peer we are connected to.
#[derive(Debug, PartialEq, Clone, Copy)]
enum PeerSocket<RId> {
    PeerToPeer {
        source: SocketAddr,
        dest: SocketAddr,
    },
    PeerToRelay {
        source: SocketAddr,
        dest: SocketAddr,
    },
    RelayToPeer {
        relay: RId,
        dest: SocketAddr,
    },
    RelayToRelay {
        relay: RId,
        dest: SocketAddr,
    },
}

impl<RId> PeerSocket<RId> {
    fn send_from_relay(&self) -> bool {
        matches!(self, Self::RelayToPeer { .. } | Self::RelayToRelay { .. })
    }
}

impl<RId> Connection<RId>
where
    RId: PartialEq + Eq + Hash + fmt::Debug + fmt::Display + Copy + Ord,
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
                PeerSocket::PeerToPeer { dest, .. } | PeerSocket::PeerToRelay { dest, .. } => {
                    dest == addr
                }
                PeerSocket::RelayToPeer { dest: remote, .. }
                | PeerSocket::RelayToRelay { dest: remote, .. } => remote == addr,
            },
            ConnectionState::Failed | ConnectionState::Connecting { .. } => false,
        };

        from_nominated || self.possible_sockets.contains(addr)
    }

    fn wg_handshake_complete(&self, now: Instant) -> bool {
        self.tunnel.time_since_last_handshake_at(now).is_some()
    }

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
            .chain(self.state.poll_timeout())
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
        allocations: &mut BTreeMap<RId, Allocation>,
        transmits: &mut VecDeque<Transmit>,
    ) where
        TId: Copy + Ord + fmt::Display,
        RId: Copy + Ord + fmt::Display,
    {
        self.agent.handle_timeout(now);
        self.state.handle_timeout(cid, &mut self.agent, now);

        if self
            .candidate_timeout()
            .is_some_and(|timeout| now >= timeout)
        {
            tracing::info!(%cid, "Connection failed (no candidates received)");
            self.state = ConnectionState::Failed;
            return;
        }

        if self
            .disconnect_timeout()
            .is_some_and(|timeout| now >= timeout)
        {
            tracing::info!(%cid, "Connection failed (ICE timeout)");
            self.state = ConnectionState::Failed;
            return;
        }

        self.handle_tunnel_timeout(cid, now, allocations, transmits);

        // If this was a scheduled update, hop to the next interval.
        if now >= self.next_wg_timer_update {
            self.next_wg_timer_update = now + Duration::from_secs(1); // TODO: Remove fixed interval in favor of precise `next_timer_update` function in `boringtun`.
        }

        // If `boringtun` wants to be called earlier than the scheduled interval, move it forward.
        if let Some(next_update) = self.tunnel.next_timer_update() {
            if next_update < self.next_wg_timer_update {
                self.next_wg_timer_update = next_update;
            }
        }

        while let Some(event) = self.agent.poll_event() {
            match event {
                IceAgentEvent::DiscoveredRecv { source, .. } => {
                    self.possible_sockets.insert(source);
                }
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
                    let source_relay = allocations.iter().find_map(|(relay, allocation)| {
                        allocation.has_socket(source).then_some(*relay)
                    });
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
                        (Some(relay), false) => PeerSocket::RelayToPeer {
                            relay,
                            dest: destination,
                        },
                        (Some(relay), true) => PeerSocket::RelayToRelay {
                            relay,
                            dest: destination,
                        },
                    };

                    let old = match mem::replace(&mut self.state, ConnectionState::Failed) {
                        ConnectionState::Connecting {
                            wg_buffer,
                            ip_buffer,
                            ..
                        } => {
                            tracing::debug!(
                                num_buffered = %wg_buffer.len(),
                                %cid,
                                "Flushing WireGuard packets buffered during ICE"
                            );

                            transmits.extend(wg_buffer.into_iter().flat_map(|packet| {
                                make_owned_transmit(
                                    remote_socket,
                                    &packet,
                                    &self.buffer_pool,
                                    allocations,
                                    now,
                                )
                            }));

                            tracing::debug!(
                                num_buffered = %ip_buffer.len(),
                                %cid,
                                "Flushing IP packets buffered during ICE"
                            );
                            transmits.extend(ip_buffer.into_iter().flat_map(|packet| {
                                let transmit = self
                                    .encapsulate(cid, remote_socket, packet, now, allocations)
                                    .inspect_err(|e| {
                                        tracing::debug!(
                                            %cid,
                                            "Failed to encapsulate buffered IP packet: {e:#}"
                                        )
                                    })
                                    .ok()??;

                                Some(transmit)
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
                            self.state = ConnectionState::Idle {
                                peer_socket: remote_socket,
                            };

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
            let stun_packet = transmit.contents;

            // Check if `str0m` wants us to send from a "remote" socket, i.e. one that we allocated with a relay.
            let allocation = allocations
                .iter_mut()
                .find(|(_, allocation)| allocation.has_socket(source));

            let Some((relay, allocation)) = allocation else {
                self.stats.stun_bytes_to_peer_direct += stun_packet.len();

                // `source` did not match any of our allocated sockets, must be a local one then!
                transmits.push_back(Transmit {
                    src: Some(source),
                    dst,
                    payload: self.buffer_pool.pull_initialised(&Vec::from(stun_packet)),
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
            });
        }
    }

    fn handle_tunnel_timeout<TId>(
        &mut self,
        cid: TId,
        now: Instant,
        allocations: &mut BTreeMap<RId, Allocation>,
        transmits: &mut VecDeque<Transmit>,
    ) where
        TId: fmt::Display,
    {
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
                tracing::info!(%cid, "Connection failed (wireguard tunnel expired)");
                self.state = ConnectionState::Failed;
            }
            TunnResult::Err(e) => {
                tracing::warn!(%cid, "boringtun error: {e}");
            }
            TunnResult::WriteToNetwork(b) => {
                transmits.extend(make_owned_transmit(
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
        socket: PeerSocket<RId>,
        packet: IpPacket,
        now: Instant,
        allocations: &mut BTreeMap<RId, Allocation>,
    ) -> Result<Option<Transmit>>
    where
        TId: fmt::Display,
    {
        self.state.on_outgoing(cid, &mut self.agent, &packet, now);

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
            })),
            PeerSocket::RelayToPeer { relay, dest: peer }
            | PeerSocket::RelayToRelay { relay, dest: peer } => {
                let Some(allocation) = allocations.get_mut(&relay) else {
                    tracing::warn!(%relay, "No allocation");
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
                }))
            }
        }
    }

    fn decapsulate<TId>(
        &mut self,
        cid: TId,
        src: IpAddr,
        packet: &[u8],
        allocations: &mut BTreeMap<RId, Allocation>,
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
                    ConnectionState::Connecting { wg_buffer, .. } => {
                        tracing::debug!(%cid, "No socket has been nominated yet, buffering WG packet");

                        wg_buffer.push(bytes.to_owned());

                        while let TunnResult::WriteToNetwork(packet) =
                            self.tunnel
                                .decapsulate_at(None, &[], self.buffer.as_mut(), now)
                        {
                            wg_buffer.push(packet.to_owned());
                        }
                    }
                    ConnectionState::Connected { peer_socket, .. }
                    | ConnectionState::Idle { peer_socket } => {
                        transmits.extend(make_owned_transmit(
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

    fn force_handshake(
        &mut self,
        allocations: &mut BTreeMap<RId, Allocation>,
        transmits: &mut VecDeque<Transmit>,
        now: Instant,
    ) where
        RId: Copy,
    {
        /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
        ///
        /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
        const MAX_SCRATCH_SPACE: usize = 148;

        let mut buf = [0u8; MAX_SCRATCH_SPACE];

        let TunnResult::WriteToNetwork(bytes) = self
            .tunnel
            .format_handshake_initiation_at(&mut buf, false, now)
        else {
            return;
        };

        let socket = self
            .socket()
            .expect("cannot force handshake while not connected");

        transmits.extend(make_owned_transmit(
            socket,
            bytes,
            &self.buffer_pool,
            allocations,
            now,
        ));
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
    buffer_pool: &BufferPool<Vec<u8>>,
    allocations: &mut BTreeMap<RId, Allocation>,
    now: Instant,
) -> Option<Transmit>
where
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug,
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
        },
        PeerSocket::RelayToPeer { relay, dest: peer }
        | PeerSocket::RelayToRelay { relay, dest: peer } => {
            let allocation = allocations.get_mut(&relay)?;

            let mut channel_data = channel_data_packet_buffer(message);
            let encode_ok = allocation.encode_channel_data_header(peer, &mut channel_data, now)?;

            Transmit {
                src: None,
                dst: encode_ok.socket,
                payload: buffer_pool.pull_initialised(&channel_data),
            }
        }
    };

    Some(transmit)
}

fn new_agent() -> IceAgent {
    let mut agent = IceAgent::new();
    agent.set_timing_advance(Duration::ZERO);
    apply_default_stun_timings(&mut agent);

    agent
}

fn apply_default_stun_timings(agent: &mut IceAgent) {
    agent.set_max_stun_retransmits(12);
    agent.set_max_stun_rto(Duration::from_millis(1500));
    agent.set_initial_stun_rto(Duration::from_millis(250))
}

fn apply_idle_stun_timings(agent: &mut IceAgent) {
    agent.set_max_stun_retransmits(4);
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
    use std::net::{IpAddr, Ipv4Addr, SocketAddrV4};

    use super::*;

    #[test]
    fn default_ice_timeout() {
        let mut agent = IceAgent::new();

        apply_default_stun_timings(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_millis(15250))
    }

    #[test]
    fn idle_ice_timeout() {
        let mut agent = IceAgent::new();

        apply_idle_stun_timings(&mut agent);

        assert_eq!(agent.ice_timeout(), Duration::from_secs(100))
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
}
