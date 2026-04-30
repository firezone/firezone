use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    fmt,
    hash::Hash,
    iter,
    sync::{Arc, atomic::AtomicU32},
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, bail};
use boringtun::noise::Index;
use is::stun::{StunMessage, TransId};
use rand::Rng;

use crate::{
    ConnectionStats, Event,
    node::{Connection, allocations::Allocations, inflight_stun_requests::InflightStunRequests},
};

pub struct Connections<TId, RId> {
    established: BTreeMap<TId, Connection<RId>>,

    established_by_wireguard_session_index: BTreeMap<usize, TId>,
    established_by_local_ufrag: BTreeMap<String, TId>,

    disconnected_ids: BTreeMap<TId, Instant>,
    disconnected_public_keys: BTreeMap<[u8; 32], Instant>,
    disconnected_session_indices: BTreeMap<usize, Instant>,

    connections_with_removed_relays: BTreeSet<TId>,
    disconnected_ufrags: BTreeMap<String, Instant>,
}

impl<TId, RId> Default for Connections<TId, RId> {
    fn default() -> Self {
        Self {
            established: Default::default(),
            established_by_wireguard_session_index: Default::default(),
            established_by_local_ufrag: Default::default(),
            disconnected_ids: Default::default(),
            disconnected_public_keys: Default::default(),
            disconnected_session_indices: Default::default(),
            connections_with_removed_relays: Default::default(),
            disconnected_ufrags: Default::default(),
        }
    }
}

impl<TId, RId> Connections<TId, RId>
where
    TId: Eq + Hash + Copy + Ord + fmt::Display,
    RId: Copy + Eq + Hash + PartialEq + Ord + fmt::Debug + fmt::Display,
{
    const RECENT_DISCONNECT_TIMEOUT: Duration = Duration::from_secs(5);

    pub(crate) fn handle_timeout(&mut self, events: &mut VecDeque<Event<TId>>, now: Instant) {
        for (id, conn) in self.established.extract_if(.., |_, conn| conn.is_failed()) {
            events.push_back(Event::ConnectionFailed(id));

            for (index, _) in self
                .established_by_wireguard_session_index
                .extract_if(.., |_, c| *c == id)
            {
                self.disconnected_session_indices.insert(index, now);
            }
            self.disconnected_public_keys
                .insert(conn.tunnel.remote_static_public().to_bytes(), now);
            self.disconnected_ids.insert(id, now);
            self.disconnected_ufrags
                .insert(conn.agent.local_credentials().ufrag.to_owned(), now);
        }

        self.disconnected_ids
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
        self.disconnected_public_keys
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
        self.disconnected_session_indices
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
        self.disconnected_ufrags
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
    }

    pub(crate) fn remove_established(&mut self, id: &TId, now: Instant) -> Option<Connection<RId>> {
        let connection = self.established.remove(id)?;

        self.established_by_wireguard_session_index
            .remove(&connection.index.global());
        self.established_by_local_ufrag
            .remove(&connection.agent.local_credentials().ufrag);

        self.disconnected_ids.insert(*id, now);
        self.disconnected_public_keys
            .insert(connection.tunnel.remote_static_public().to_bytes(), now);
        self.disconnected_session_indices
            .insert(connection.index.global(), now);
        self.disconnected_ufrags
            .insert(connection.agent.local_credentials().ufrag.to_owned(), now);

        Some(connection)
    }

    pub(crate) fn migrate_relays(
        &mut self,
        removed_allocations: impl Iterator<Item = RId>,
        allocations: &Allocations<RId>,
        pending_events: &mut VecDeque<Event<TId>>,
        rng: &mut impl Rng,
        now: Instant,
    ) {
        // Temporarily take ownership of buffer to satisfy borrow-checker.
        let mut connections_with_removed_relays =
            std::mem::take(&mut self.connections_with_removed_relays);

        for removed_relay in removed_allocations {
            for (cid, c) in self.iter_mut_by_relay(removed_relay) {
                let Some((new_relay, new_allocation)) = allocations.sample(rng) else {
                    let was_inserted = connections_with_removed_relays.insert(cid);

                    if was_inserted {
                        tracing::debug!(%cid, "Failed to sample new relay for connection");
                    }

                    continue;
                };

                c.migrate_relay(cid, new_relay, new_allocation, pending_events);
            }
        }

        for cid in connections_with_removed_relays {
            let Some((new_relay, new_allocation)) = allocations.sample(rng) else {
                self.connections_with_removed_relays.insert(cid);

                continue;
            };

            let Ok(c) = self.get_mut(&cid, now) else {
                continue;
            };

            c.migrate_relay(cid, new_relay, new_allocation, pending_events);
        }
    }

    pub(crate) fn stats(&self) -> impl Iterator<Item = (TId, ConnectionStats)> + '_ {
        self.established.iter().map(move |(id, c)| (*id, c.stats))
    }

    pub(crate) fn insert_established(
        &mut self,
        id: TId,
        index: Index,
        connection: Connection<RId>,
    ) -> Option<Connection<RId>> {
        let local_ufrag = connection.agent.local_credentials().ufrag.to_owned();
        let existing = self.established.insert(id, connection);

        // Remove previous mappings for connection.
        self.established_by_wireguard_session_index
            .retain(|_, c| c != &id);
        self.established_by_wireguard_session_index
            .insert(index.global(), id);
        self.established_by_local_ufrag.insert(local_ufrag, id);

        existing
    }

    pub(crate) fn iter_mut_by_relay(
        &mut self,
        id: RId,
    ) -> impl Iterator<Item = (TId, &mut Connection<RId>)> + '_ {
        self.established
            .iter_mut()
            .filter_map(move |(cid, c)| (c.relay.id == id).then_some((*cid, c)))
    }

    pub(crate) fn get_mut(&mut self, id: &TId, now: Instant) -> Result<&mut Connection<RId>> {
        let connection = self
            .established
            .get_mut(id)
            .with_context(|| UnknownConnection::by_id(*id, &self.disconnected_ids, now))?;

        Ok(connection)
    }

    pub(crate) fn get_established_mut_session_index(
        &mut self,
        index: Index,
        now: Instant,
    ) -> Result<(TId, &mut Connection<RId>)> {
        let id = self
            .established_by_wireguard_session_index
            .get(&index.global())
            .with_context(|| {
                UnknownConnection::by_index(index.global(), &self.disconnected_session_indices, now)
            })?;

        let connection = self
            .established
            .get_mut(id)
            .with_context(|| UnknownConnection::by_id(*id, &self.disconnected_ids, now))?;

        Ok((*id, connection))
    }

    pub(crate) fn get_established_mut_by_public_key(
        &mut self,
        key: [u8; 32],
        now: Instant,
    ) -> Result<(TId, &mut Connection<RId>)> {
        let (id, conn) = self
            .established
            .iter_mut()
            .find(|(_, c)| c.tunnel.remote_static_public().as_bytes() == &key)
            .with_context(|| {
                UnknownConnection::by_public_key(key, &self.disconnected_public_keys, now)
            })?;

        Ok((*id, conn))
    }

    pub(crate) fn get_established_mut_for_stun_message(
        &mut self,
        message: &StunMessage,
        inflight_stun_requests: &mut InflightStunRequests<TId>,
        now: Instant,
    ) -> Result<(TId, &mut Connection<RId>)> {
        if message.is_binding_request() {
            let (ufrag, _) = message
                .split_username()
                .context("Binding request does not have a USERNAME attribute")?;
            let id = self
                .established_by_local_ufrag
                .get(ufrag)
                .ok_or(UnknownConnection::by_local_ufrag(
                    ufrag,
                    &self.disconnected_ufrags,
                    now,
                ))
                .copied()?;
            let conn = self.get_mut(&id, now)?;

            return Ok((id, conn));
        }

        if message.is_successful_binding_response() {
            let trans_id = message.trans_id();
            let id = inflight_stun_requests
                .remove(trans_id)
                .ok_or(UnknownConnection::by_trans_id(trans_id))?;
            let conn = self.get_mut(&id, now)?;

            return Ok((id, conn));
        }

        bail!("STUN message is not a BINDING")
    }

    pub(crate) fn iter_established(&self) -> impl Iterator<Item = (TId, &Connection<RId>)> {
        self.established.iter().map(|(id, conn)| (*id, conn))
    }

    pub(crate) fn iter_established_mut(
        &mut self,
    ) -> impl Iterator<Item = (TId, &mut Connection<RId>)> {
        self.established.iter_mut().map(|(id, conn)| (*id, conn))
    }

    pub(crate) fn len(&self) -> usize {
        self.established.len()
    }

    /// Replace each established connection's [`is::IceAgent`] with a fresh
    /// one, preserving the WireGuard session and routing identity.
    ///
    /// See [`Connection::recreate_agent`] for the per-connection details.
    pub(crate) fn recreate_agents(&mut self, unix_ms: u64) {
        for connection in self.established.values_mut() {
            connection.recreate_agent(unix_ms);
        }
    }

    pub(crate) fn iter_ids(&self) -> impl Iterator<Item = TId> + '_ {
        self.established.keys().copied()
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            .chain(
                self.established
                    .values_mut()
                    .filter_map(|c| c.poll_timeout()),
            )
            .chain(
                self.disconnected_ids
                    .values()
                    .map(|t| {
                        (
                            *t + Self::RECENT_DISCONNECT_TIMEOUT,
                            "recently disconnected IDs",
                        )
                    })
                    .min_by_key(|(t, _)| *t),
            )
            .chain(
                self.disconnected_public_keys
                    .values()
                    .map(|t| {
                        (
                            *t + Self::RECENT_DISCONNECT_TIMEOUT,
                            "recently disconnected public keys",
                        )
                    })
                    .min_by_key(|(t, _)| *t),
            )
            .chain(
                self.disconnected_session_indices
                    .values()
                    .map(|t| {
                        (
                            *t + Self::RECENT_DISCONNECT_TIMEOUT,
                            "recently disconnected session indices",
                        )
                    })
                    .min_by_key(|(t, _)| *t),
            )
            .min_by_key(|(instant, _)| *instant)
    }
}

#[derive(Debug)]
pub struct UnknownConnection {
    kind: &'static str,
    id: String,
    disconnected_for: Option<Duration>,
}

impl UnknownConnection {
    fn by_id<TId>(id: TId, disconnected_ids: &BTreeMap<TId, Instant>, now: Instant) -> Self
    where
        TId: fmt::Display + Eq + Ord,
    {
        Self {
            id: id.to_string(),
            kind: "id",
            disconnected_for: disconnected_ids
                .get(&id)
                .map(|disconnected| now.duration_since(*disconnected)),
        }
    }

    fn by_index(id: usize, disconnected_indices: &BTreeMap<usize, Instant>, now: Instant) -> Self {
        Self {
            id: id.to_string(),
            kind: "index",
            disconnected_for: disconnected_indices
                .get(&id)
                .map(|disconnected| now.duration_since(*disconnected)),
        }
    }

    fn by_public_key(
        key: [u8; 32],
        disconnected_public_keys: &BTreeMap<[u8; 32], Instant>,
        now: Instant,
    ) -> Self {
        Self {
            id: into_u256(key).to_string(),
            kind: "public key",
            disconnected_for: disconnected_public_keys
                .get(&key)
                .map(|disconnected| now.duration_since(*disconnected)),
        }
    }

    fn by_local_ufrag(
        key: &str,
        disconnected_ufrags: &BTreeMap<String, Instant>,
        now: Instant,
    ) -> Self {
        Self {
            id: key.to_owned(),
            kind: "ufrag",
            disconnected_for: disconnected_ufrags
                .get(key)
                .map(|disconnected| now.duration_since(*disconnected)),
        }
    }

    fn by_trans_id(key: TransId) -> Self {
        Self {
            id: format!("{key:?}"),
            kind: "STUN trans ID",
            disconnected_for: None,
        }
    }

    pub fn recently_disconnected(&self) -> bool {
        self.disconnected_for.is_some()
    }
}

impl std::error::Error for UnknownConnection {}

impl fmt::Display for UnknownConnection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "No connection for {} {}", self.kind, self.id)?;

        if let Some(disconnected_for) = self.disconnected_for {
            write!(f, " (disconnected for {disconnected_for:?})")?;
        }

        Ok(())
    }
}

fn into_u256(key: [u8; 32]) -> bnum::Uint<32> {
    bnum::types::U256::from_str_radix(&hex::encode(key), 16)
        .expect("array of 32 u8's fits into u256")
}

#[cfg(test)]
mod tests {
    use boringtun::{
        noise::Tunn,
        x25519::{PublicKey, StaticSecret},
    };
    use bufferpool::BufferPool;
    use is::IceAgent;
    use rand::random;
    use ringbuffer::AllocRingBuffer;

    use std::net::{Ipv4Addr, SocketAddrV4};

    use crate::{
        RelaySocket,
        node::{ConnectionState, SelectedRelay, allocations::Allocations},
    };
    use stun_codec::rfc5389::attributes::{Realm, Username};

    use super::*;

    #[test]
    fn explicitly_removed_connection() {
        let mut connections = Connections::default();
        let mut now = Instant::now();

        let (id, idx, key) = insert_dummy_connection(&mut connections);

        connections.remove_established(&id, now);
        connections.handle_timeout(&mut VecDeque::default(), now);

        now += Duration::from_secs(1);

        assert_disconnected(&mut connections, id, idx, key, now, true);

        now += Duration::from_secs(5);
        connections.handle_timeout(&mut VecDeque::default(), now);

        assert_disconnected(&mut connections, id, idx, key, now, false);
    }

    #[test]
    fn failed_connection() {
        let mut connections = Connections::default();
        let mut now = Instant::now();

        let (id, idx, key) = insert_dummy_connection(&mut connections);

        connections.get_mut(&id, now).unwrap().state = ConnectionState::Failed;
        connections.handle_timeout(&mut VecDeque::default(), now);
        now += Duration::from_secs(1);

        assert_disconnected(&mut connections, id, idx, key, now, true);

        now += Duration::from_secs(5);
        connections.handle_timeout(&mut VecDeque::default(), now);

        assert_disconnected(&mut connections, id, idx, key, now, false);
    }

    #[test]
    fn can_make_u256_out_of_byte_array() {
        let bytes = random();
        let _num = into_u256(bytes);
    }

    #[test]
    fn u256_renders_as_int() {
        let num = into_u256([1; 32]);

        assert_eq!(
            num.to_string(),
            "454086624460063511464984254936031011189294057512315937409637584344757371137"
        );
    }

    #[test]
    fn migrate_relay_retries_connections_that_previously_had_no_allocation() {
        let mut connections: Connections<u32, u32> = Connections::default();
        let mut allocations: Allocations<u32> = Allocations::default();
        let now = Instant::now();
        let mut rng = rand::thread_rng();

        // Insert a connection that is using relay id 1.
        let conn = new_connection(12345, 1, [1u8; 32]);
        connections.insert_established(1, conn.index, conn);

        // First call: relay 1 is removed but no allocations are available.
        let mut pending_events = VecDeque::new();
        connections.migrate_relays(
            std::iter::once(1u32),
            &allocations,
            &mut pending_events,
            &mut rng,
            now,
        );

        // The connection still uses relay 1 because no new relay was available.
        assert_eq!(connections.get_mut(&1, now).unwrap().relay.id, 1);

        allocations.upsert(
            2,
            RelaySocket::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 3478)),
            Username::new("user".to_owned()).unwrap(),
            "pass".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            now,
        );
        // Simulate a successful response so the relay is eligible for sampling.
        allocations
            .get_mut_by_id(&2)
            .unwrap()
            .set_rtt(Duration::from_millis(20));

        connections.migrate_relays(
            std::iter::empty(),
            &allocations,
            &mut pending_events,
            &mut rng,
            now,
        );

        // The connection should now be using the new relay (id 2).
        assert_eq!(connections.get_mut(&1, now).unwrap().relay.id, 2);
    }

    fn insert_dummy_connection(connections: &mut Connections<u32, u32>) -> (u32, Index, PublicKey) {
        let conn = new_connection(12345, 0, [1u8; 32]);
        let id = 1;
        let idx = conn.index;
        let key = conn.tunnel.remote_static_public();
        connections.insert_established(id, conn.index, conn);

        (id, idx, key)
    }

    #[expect(clippy::disallowed_methods, reason = "This is a test.")]
    fn assert_disconnected(
        connections: &mut Connections<u32, u32>,
        id: u32,
        idx: Index,
        key: PublicKey,
        now: Instant,
        is_recently_disconnected: bool,
    ) {
        // Get by ID
        let err = connections
            .get_mut(&id, now)
            .unwrap_err()
            .downcast::<UnknownConnection>()
            .unwrap();

        assert_eq!(err.recently_disconnected(), is_recently_disconnected);

        // Get by index
        let err = connections
            .get_established_mut_session_index(idx, now)
            .unwrap_err()
            .downcast::<UnknownConnection>()
            .unwrap();

        assert_eq!(err.recently_disconnected(), is_recently_disconnected);

        // Get by key
        let err = connections
            .get_established_mut_by_public_key(key.to_bytes(), now)
            .unwrap_err()
            .downcast::<UnknownConnection>()
            .unwrap();

        assert_eq!(err.recently_disconnected(), is_recently_disconnected);
    }

    fn new_connection(idx: u32, relay_id: u32, key: [u8; 32]) -> Connection<u32> {
        let private = StaticSecret::random_from_rng(rand::thread_rng());
        let new_local = Index::new_local(idx);

        Connection {
            agent: IceAgent::new(is::IceCreds::new()),
            candidate_epoch: CandidateEpoch::default(),
            index: new_local,
            tunnel: Tunn::new_at(
                private,
                PublicKey::from(key),
                None,
                None,
                new_local,
                None,
                0,
                Instant::now(),
                Instant::now(),
                Duration::ZERO,
            ),
            remote_pub_key: PublicKey::from(rand::random::<[u8; 32]>()),
            next_wg_timer_update: Instant::now(),
            last_proactive_handshake_sent_at: None,
            relay: SelectedRelay { id: relay_id },
            state: crate::node::ConnectionState::Connecting {
                ip_buffer: AllocRingBuffer::new(1),
                session_socket: None,
            },
            outbound_handshakes: Default::default(),
            stats: Default::default(),
            intent_sent_at: Instant::now(),
            candidate_timeout: None,
            first_handshake_completed_at: None,
            buffer: Default::default(),
            buffer_pool: BufferPool::new(0, "test"),
            poll_timeout_cache: Default::default(),
        }
    }
}

/// Models the current epoch of a single connection's candidates.
///
/// ICE selects the best candidate pair based on "priority", which for each candidate is composed of
/// its kind (host, srflx, prflx, relayed), IP version, and a user-provided "local preference".
/// Standard local-preference values live within a 16-bit range, but the [`is`] priority layout
/// (type_preference << 24 | local_preference << 8 | component) permits a few more bits of headroom
/// before the `prio < 2^31` assertion trips — enough to pack a monotonic epoch counter on top.
///
/// Each time this connection roams or otherwise acquires candidates that supersede older ones, we
/// bump the epoch by [`EPOCH_BUMP`]. The bump strictly dominates every other contribution to our
/// [`LocalPreference`] formula — the per-kind base, the IPv4/IPv6 interleave, the cumulative
/// `-2 * same_kind` penalty — so a candidate added in a new epoch *always* outranks every
/// candidate of the same kind added in a prior epoch. This lets ICE migrate to the new path without
/// any explicit ICE restart on the remote, as long as our new pairs simply outrank the old ones.
///
/// The counter is owned per-connection: a brand-new connection starts at epoch 0, and a full
/// teardown (for example after the WireGuard tunnel expires on both sides) gives us a fresh
/// counter. The counter is cloned into the connection's [`is::IceAgent`] via an `Arc` so that
/// [`CandidateEpoch::inc`] affects subsequent candidates added to the agent.
#[derive(Debug, Clone, Default)]
pub(crate) struct CandidateEpoch {
    epoch: Arc<AtomicU32>,
}

/// How much each epoch bump adds to a candidate's local preference.
///
/// Within a single epoch, the strongest same-kind candidate scores `counter_start - 0`
/// and the weakest scores `counter_start - 2 * (G - 1)` where `G` is the number of
/// same-kind candidates added in that epoch. For a new-epoch candidate to strictly
/// outrank the strongest prior-epoch candidate, we need
///
///     BUMP > 2 * G_prev
///
/// where `G_prev` is the largest number of same-kind candidates ever added in a single
/// generation. On a real Firezone session each bump adds a handful at most (one per
/// local interface, plus relay variants), so `256` clears `2 * G_prev` for any
/// realistic `G_prev`.
///
/// `EPOCH_BUMP` also caps how many bumps a single connection can survive before the
/// `prio < 2^31` assertion in [`is`] trips. For host candidates the available
/// `local_preference` headroom is ~17 bits (≈131k), with `~65k` already spoken for
/// by `counter_start`, leaving ~64k for the epoch — i.e. ~256 bumps per connection.
/// That's effectively unlimited for any single session.
///
/// Cumulative `same_kind` underflow (`saturating_sub`) caps at ~32k same-kind
/// candidates for host kinds, independent of `BUMP`. That's a hard cap set by the
/// 16-bit width of `counter_start`.
const EPOCH_BUMP: u32 = 256;

impl CandidateEpoch {
    fn current(&self) -> u32 {
        self.epoch.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub(crate) fn inc(&self) {
        self.epoch
            .fetch_add(EPOCH_BUMP, std::sync::atomic::Ordering::Relaxed);

        tracing::debug!(current = %self.current(), "Bumping candidate epoch");
    }
}

pub(crate) struct LocalPreference {
    epoch: CandidateEpoch,
}

impl LocalPreference {
    pub(crate) fn new(epoch: CandidateEpoch) -> Self {
        Self { epoch }
    }
}

/// Per-kind starting preference. Higher kinds rank above lower ones; within a
/// kind, IPv6 ranks one above IPv4 of the same kind (interleaved odd/even).
const COUNTER_START_HOST: u32 = 65_535;
const COUNTER_START_PEER_REFLEXIVE: u32 = 49_151;
const COUNTER_START_SERVER_REFLEXIVE: u32 = 32_767;
const COUNTER_START_RELAYED: u32 = 16_383;

impl is::LocalPreference for LocalPreference {
    /// Computes a candidate's local preference.
    ///
    /// The formula mirrors `is::default_local_preference` but inlines it so we
    /// own the math: per-kind `counter_start`, IPv4/IPv6 interleave, and a
    /// `-2 * same_kind` penalty. We deliberately drop the
    /// `relay_across_ip_version_punishment` from the upstream formula — that
    /// constant was `1000`, large enough to overwhelm any realistic
    /// [`EPOCH_BUMP`], which would let a punished new-epoch candidate rank
    /// below an unpunished prior-epoch candidate of the same kind. The kind
    /// ordering already deprioritises relayed candidates against host /
    /// reflexive ones, and ICE connectivity checks will discover whichever
    /// pair actually works.
    ///
    /// On top of the base, we add the connection's current epoch. By
    /// construction `EPOCH_BUMP` strictly dominates the worst-case base
    /// reduction within any one generation, so a new-epoch candidate always
    /// outranks every prior-epoch candidate of the same kind.
    fn calculate(&self, c: &is::Candidate, same_kind: usize) -> u32 {
        let counter_start = match c.kind() {
            is::CandidateKind::Host => COUNTER_START_HOST,
            is::CandidateKind::PeerReflexive => COUNTER_START_PEER_REFLEXIVE,
            is::CandidateKind::ServerReflexive => COUNTER_START_SERVER_REFLEXIVE,
            is::CandidateKind::Relayed => COUNTER_START_RELAYED,
        };
        let ipv4_offset = u32::from(c.addr().is_ipv4());
        let same_kind_penalty = 2 * same_kind as u32;

        let base = counter_start
            .saturating_sub(ipv4_offset)
            .saturating_sub(same_kind_penalty);

        base.saturating_add(self.epoch.current())
    }
}

#[cfg(test)]
mod local_preference_tests {
    //! Direct unit tests on [`LocalPreference::calculate`].
    //!
    //! These cover the invariants of the formula itself, independent of any
    //! `IceAgent` machinery. The agent-level tests in [`candidate_epoch_tests`]
    //! exercise the same invariants end-to-end via `prio()`.

    use super::*;
    use is::{Candidate, LocalPreference as _};

    fn host(addr: &str) -> Candidate {
        Candidate::host(addr.parse().unwrap(), "udp").unwrap()
    }

    fn srflx(addr: &str, base: &str) -> Candidate {
        Candidate::server_reflexive(addr.parse().unwrap(), base.parse().unwrap(), "udp").unwrap()
    }

    fn relay(addr: &str, base: &str) -> Candidate {
        Candidate::relayed(addr.parse().unwrap(), base.parse().unwrap(), "udp").unwrap()
    }

    fn pref(c: &Candidate, same_kind: usize, epoch: &CandidateEpoch) -> u32 {
        LocalPreference::new(epoch.clone()).calculate(c, same_kind)
    }

    #[test]
    fn host_outranks_srflx_outranks_relay() {
        let epoch = CandidateEpoch::default();
        let h = host("1.1.1.1:1000");
        let s = srflx("1.1.1.2:1001", "192.168.1.1:1000");
        let r = relay("1.1.1.3:1002", "192.168.1.1:1000");

        assert!(pref(&h, 0, &epoch) > pref(&s, 0, &epoch));
        assert!(pref(&s, 0, &epoch) > pref(&r, 0, &epoch));
    }

    #[test]
    fn ipv6_outranks_ipv4_within_same_kind() {
        let epoch = CandidateEpoch::default();
        let v6 = host("[2001:db8::1]:1000");
        let v4 = host("1.1.1.1:1000");

        assert_eq!(pref(&v6, 0, &epoch), pref(&v4, 0, &epoch) + 1);
    }

    #[test]
    fn same_kind_penalty_is_two_per_step() {
        let epoch = CandidateEpoch::default();
        let h = host("1.1.1.1:1000");

        assert_eq!(pref(&h, 0, &epoch) - pref(&h, 1, &epoch), 2);
        assert_eq!(pref(&h, 1, &epoch) - pref(&h, 2, &epoch), 2);
        assert_eq!(pref(&h, 5, &epoch) - pref(&h, 10, &epoch), 10);
    }

    /// Each epoch bump adds exactly [`EPOCH_BUMP`] to the result, holding
    /// kind / IP / same_kind constant.
    #[test]
    fn epoch_bump_adds_exactly_bump_to_preference() {
        let epoch = CandidateEpoch::default();
        let h = host("1.1.1.1:1000");

        let before = pref(&h, 0, &epoch);
        epoch.inc();
        let after = pref(&h, 0, &epoch);

        assert_eq!(after - before, EPOCH_BUMP);
    }

    /// Critical invariant: for the same kind, a candidate from a new epoch
    /// strictly outranks *every* candidate from the prior epoch — regardless
    /// of how many same-kind candidates the prior generation contained.
    ///
    /// We test up to a generation size that matches `EPOCH_BUMP / 2 - 1`
    /// (the largest `G_prev` for which the formula `BUMP > 2 * G_prev`
    /// still holds strictly), and verify both the boundary and a comfortable
    /// realistic value.
    #[test]
    fn new_epoch_outranks_prior_epoch_within_same_kind() {
        for g_prev in [1usize, 5, 20, 100, (EPOCH_BUMP as usize) / 2 - 1] {
            let epoch = CandidateEpoch::default();
            let h = host("1.1.1.1:1000");

            // Strongest in the prior generation: same_kind = 0.
            let prior_strongest = pref(&h, 0, &epoch);

            epoch.inc();

            // First candidate in the new generation inherits cumulative
            // same_kind = g_prev from the prior generation.
            let new_first = pref(&h, g_prev, &epoch);

            assert!(
                new_first > prior_strongest,
                "with G_prev = {g_prev}, EPOCH_BUMP = {EPOCH_BUMP}: \
                 new_first ({new_first}) must outrank prior_strongest ({prior_strongest})"
            );
        }
    }

    /// The invariant must also hold across multiple epoch bumps: every
    /// candidate added after `n` bumps strictly outranks every candidate
    /// added before any of those bumps.
    #[test]
    fn invariant_holds_across_many_consecutive_bumps() {
        let epoch = CandidateEpoch::default();
        let h = host("1.1.1.1:1000");

        let original = pref(&h, 0, &epoch);

        for cumulative_same_kind in 1..=50 {
            epoch.inc();
            let next = pref(&h, cumulative_same_kind, &epoch);
            assert!(
                next > original,
                "after epoch bump: next ({next}) must outrank original ({original})"
            );
        }
    }
}

#[cfg(test)]
mod candidate_epoch_tests {
    use super::*;
    use is::{Candidate, IceAgent, IceCreds};

    /// After one epoch bump, a newly added same-kind candidate must outrank
    /// any prior same-kind candidate despite the `-2 * same_kind` penalty.
    ///
    /// This is the invariant that makes generational candidates work against
    /// any ICE implementation that nominates by priority — including old
    /// Gateways that know nothing about our epoch scheme.
    #[test]
    fn bumped_epoch_outranks_prior_same_kind_candidate() {
        let epoch = CandidateEpoch::default();
        let mut agent = IceAgent::new(IceCreds::new());
        agent.set_local_preference(LocalPreference::new(epoch.clone()));

        let first = agent
            .add_local_candidate(host_candidate("1.1.1.1:1000"))
            .unwrap()
            .clone();

        epoch.inc();

        let second = agent
            .add_local_candidate(host_candidate("2.2.2.2:2000"))
            .unwrap()
            .clone();

        assert!(
            second.prio() > first.prio(),
            "epoch bump ({EPOCH_BUMP}) must dominate the -2*same_kind penalty: \
             first={}, second={}",
            first.prio(),
            second.prio()
        );
    }

    /// The strongest candidate of the new epoch must strictly outrank the
    /// strongest candidate of the prior epoch. The strongest in either gen
    /// is the FIRST one added (lowest `same_kind` penalty); after a generation
    /// of size `G_PREV`, the new gen's first candidate is `BUMP - 2 * G_PREV`
    /// ahead of the prior gen's first candidate.
    ///
    /// This is the invariant that lets ICE migrate: as long as the best new
    /// pair beats the best old pair on local-preference, ICE picks the new
    /// pair.
    #[test]
    fn strongest_of_new_epoch_outranks_strongest_of_prior() {
        // Realistic upper bound on same-kind candidates added per generation.
        // One per local interface, plus relay-derived variants — well below
        // this on any real machine.
        const G_PREV: usize = 20;

        let epoch = CandidateEpoch::default();
        let mut agent = IceAgent::new(IceCreds::new());
        agent.set_local_preference(LocalPreference::new(epoch.clone()));

        let strongest_prior = agent
            .add_local_candidate(host_candidate("10.0.0.1:1000"))
            .unwrap()
            .clone();

        // Pad out the prior generation.
        for i in 1..G_PREV {
            let addr = format!("10.0.0.1:{}", 1000 + i);
            agent.add_local_candidate(host_candidate(&addr));
        }

        epoch.inc();

        let strongest_new = agent
            .add_local_candidate(host_candidate("2.2.2.2:2000"))
            .unwrap()
            .clone();

        assert!(
            strongest_new.prio() > strongest_prior.prio(),
            "strongest of new epoch must outrank strongest of prior epoch \
             after a generation of {G_PREV} same-kind candidates: \
             strongest_prior={}, strongest_new={}",
            strongest_prior.prio(),
            strongest_new.prio()
        );
    }

    /// Candidates added across consecutive epoch bumps must have strictly
    /// increasing priority, across the range we actually use (well below the
    /// `prio < 2^31` assertion inside `is`).
    #[test]
    fn priorities_are_monotonically_increasing_across_bumps() {
        let epoch = CandidateEpoch::default();
        let mut agent = IceAgent::new(IceCreds::new());
        agent.set_local_preference(LocalPreference::new(epoch.clone()));

        let mut prev = agent
            .add_local_candidate(host_candidate("10.0.0.1:1000"))
            .unwrap()
            .prio();

        for i in 0..10 {
            epoch.inc();
            let addr = format!("10.0.0.1:{}", 2000 + i);
            let next = agent
                .add_local_candidate(host_candidate(&addr))
                .unwrap()
                .prio();
            assert!(next > prev);
            prev = next;
        }
    }

    fn host_candidate(addr: &str) -> Candidate {
        Candidate::host(addr.parse().unwrap(), "udp").unwrap()
    }
}
