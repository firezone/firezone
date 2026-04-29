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

                c.migrate_relay(cid, new_relay, new_allocation, pending_events, now);
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

            c.migrate_relay(cid, new_relay, new_allocation, pending_events, now);
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

    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = (TId, &mut Connection<RId>)> {
        self.established.iter_mut().map(|(id, c)| (*id, c))
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

    pub(crate) fn clear(&mut self) {
        self.established.clear();
        self.established_by_wireguard_session_index.clear();
    }

    pub(crate) fn iter_ids(&self) -> impl Iterator<Item = TId> + '_ {
        self.established.keys().copied()
    }

    pub(crate) fn all_idle(&self) -> bool {
        self.established.values().all(|c| c.is_idle())
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
        IceConfig, RelaySocket,
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
                wg_buffer: AllocRingBuffer::new(1),
                ip_buffer: AllocRingBuffer::new(1),
            },
            disconnected_at: None,
            stats: Default::default(),
            intent_sent_at: Instant::now(),
            candidate_timeout: None,
            first_handshake_completed_at: None,
            buffer: Default::default(),
            buffer_pool: BufferPool::new(0, "test"),
            default_ice_config: IceConfig::client_default(),
            idle_ice_config: IceConfig::client_idle(),
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
/// bump the epoch by [`EPOCH_BUMP`]. That shift dominates the `-2 * same_kind` penalty within
/// [`is::default_local_preference`], so newly added candidates always rank strictly higher than
/// candidates from prior epochs of the same kind. This lets ICE migrate to the new path without
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
/// [`is::default_local_preference`] subtracts `2 * same_kind` per candidate, where
/// `same_kind` is the *cumulative* count of same-kind candidates already on the agent.
/// Both that penalty and the epoch contribution accumulate across generations, but they
/// scale together: the strongest candidate of a new epoch outranks the strongest candidate
/// of the prior epoch by `BUMP - 2 * G_prev`, where `G_prev` is the number of same-kind
/// candidates added in the prior generation. So we just need `BUMP > 2 * G_max`, where
/// `G_max` is the largest number of same-kind candidates we ever add between bumps.
///
/// Each bump on a real Firezone session adds at most a handful of candidates of any single
/// kind (one per local interface, plus relay variants). `50` comfortably exceeds twice that
/// even under pessimistic assumptions about per-roam interface count, leaving the
/// strongest-of-new strictly above the strongest-of-prior.
///
/// With a ~65k base local preference and the ~2^23 ceiling before the `prio < 2^31`
/// assertion in [`is`] trips, `50` still leaves room for ~166k epoch bumps per connection —
/// effectively unlimited for a single session.
///
/// Independent of `BUMP`, [`is::default_local_preference`] underflows once cumulative
/// `same_kind` exceeds ~32k (for host candidates: `65535 / 2`). That's a hard cap on total
/// same-kind candidates per connection, set by [`is`] itself.
const EPOCH_BUMP: u32 = 50;

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

impl is::LocalPreference for LocalPreference {
    fn calculate(&self, c: &is::Candidate, same_kind: usize) -> u32 {
        is::default_local_preference(c, same_kind).saturating_add(self.epoch.current())
    }
}

#[cfg(test)]
mod candidate_epoch_tests {
    use super::*;
    use is::{Candidate, IceAgent, IceCreds};

    /// After one epoch bump, a newly added same-kind candidate must outrank any
    /// prior same-kind candidate despite `default_local_preference`'s
    /// `-2 * same_kind` penalty.
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
