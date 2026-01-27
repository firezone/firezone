use std::{
    collections::{BTreeMap, VecDeque},
    fmt,
    hash::Hash,
    iter,
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result};
use boringtun::noise::Index;
use rand::Rng;
use str0m::ice::IceAgent;

use crate::{
    ConnectionStats, Event,
    node::{Connection, ConnectionState, allocations::Allocations, new_ice_candidate_event},
};

pub struct Connections<TId, RId> {
    established: BTreeMap<TId, Connection<RId>>,

    established_by_wireguard_session_index: BTreeMap<usize, TId>,

    disconnected_ids: BTreeMap<TId, Instant>,
    disconnected_public_keys: BTreeMap<[u8; 32], Instant>,
    disconnected_session_indices: BTreeMap<usize, Instant>,
}

impl<TId, RId> Default for Connections<TId, RId> {
    fn default() -> Self {
        Self {
            established: Default::default(),
            established_by_wireguard_session_index: Default::default(),
            disconnected_ids: Default::default(),
            disconnected_public_keys: Default::default(),
            disconnected_session_indices: Default::default(),
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
        }

        self.disconnected_ids
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
        self.disconnected_public_keys
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
        self.disconnected_session_indices
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
    }

    pub(crate) fn remove_established(&mut self, id: &TId, now: Instant) -> Option<Connection<RId>> {
        let connection = self.established.remove(id)?;

        self.established_by_wireguard_session_index
            .remove(&connection.index.global());

        self.disconnected_ids.insert(*id, now);
        self.disconnected_public_keys
            .insert(connection.tunnel.remote_static_public().to_bytes(), now);
        self.disconnected_session_indices
            .insert(connection.index.global(), now);

        Some(connection)
    }

    pub(crate) fn check_relays_available(
        &mut self,
        allocations: &Allocations<RId>,
        pending_events: &mut VecDeque<Event<TId>>,
        rng: &mut impl Rng,
        now: Instant,
    ) {
        for (cid, c) in self.iter_established_mut() {
            if allocations.contains(&c.relay.id) {
                continue; // Our relay is still there, no problems.
            }

            let Some((rid, allocation)) = allocations.sample(rng) else {
                if !c.relay.logged_sample_failure {
                    tracing::debug!(%cid, "Failed to sample new relay for connection");
                }
                c.relay.logged_sample_failure = true;

                continue;
            };

            tracing::info!(%cid, old = %c.relay.id, new = %rid, "Attempting to migrate connection to new relay");

            c.relay.id = rid;

            for candidate in allocation
                .current_relay_candidates()
                .filter_map(|candidate| c.agent.add_local_candidate(candidate).cloned())
            {
                pending_events.push_back(new_ice_candidate_event(cid, candidate));
            }

            c.state.on_candidate(cid, &mut c.agent, now);
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
        let existing = self.established.insert(id, connection);

        // Remove previous mappings for connection.
        self.established_by_wireguard_session_index
            .retain(|_, c| c != &id);
        self.established_by_wireguard_session_index
            .insert(index.global(), id);

        existing
    }

    pub(crate) fn agent_and_state_mut(
        &mut self,
        id: TId,
    ) -> Option<(&mut IceAgent, &mut ConnectionState, RId)> {
        self.established
            .get_mut(&id)
            .map(|c| (&mut c.agent, &mut c.state, c.relay.id))
    }

    pub(crate) fn agents_and_state_by_relay_mut(
        &mut self,
        id: RId,
    ) -> impl Iterator<Item = (TId, &mut IceAgent, &mut ConnectionState)> + '_ {
        self.established.iter_mut().filter_map(move |(cid, c)| {
            (c.relay.id == id).then_some((*cid, &mut c.agent, &mut c.state))
        })
    }

    pub(crate) fn agents_mut(&mut self) -> impl Iterator<Item = (TId, &mut IceAgent)> {
        self.established
            .iter_mut()
            .map(|(id, c)| (*id, &mut c.agent))
    }

    pub(crate) fn get_established_mut(
        &mut self,
        id: &TId,
        now: Instant,
    ) -> Result<&mut Connection<RId>> {
        let connection = self
            .established
            .get_mut(id)
            .context(UnknownConnection::by_id(*id, &self.disconnected_ids, now))?;

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
            .context(UnknownConnection::by_index(
                index.global(),
                &self.disconnected_session_indices,
                now,
            ))?;

        let connection = self
            .established
            .get_mut(id)
            .context(UnknownConnection::by_id(*id, &self.disconnected_ids, now))?;

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
            .context(UnknownConnection::by_public_key(
                key,
                &self.disconnected_public_keys,
                now,
            ))?;

        Ok((*id, conn))
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

fn into_u256(key: [u8; 32]) -> bnum::BUint<4> {
    // Note: `parse_str_radix` panics when the number is too big.
    // We are passing 32 u8's though which fits exactly into a u256.
    bnum::types::U256::parse_str_radix(&hex::encode(key), 16)
}

#[cfg(test)]
mod tests {
    use boringtun::{
        noise::Tunn,
        x25519::{PublicKey, StaticSecret},
    };
    use bufferpool::BufferPool;
    use rand::random;
    use ringbuffer::AllocRingBuffer;

    use crate::node::{ConnectionState, SelectedRelay};

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

        connections.get_established_mut(&id, now).unwrap().state = ConnectionState::Failed;
        connections.handle_timeout(&mut VecDeque::default(), now);
        now += Duration::from_secs(1);

        assert_disconnected(&mut connections, id, idx, key, now, true);

        now += Duration::from_secs(5);
        connections.handle_timeout(&mut VecDeque::default(), now);

        assert_disconnected(&mut connections, id, idx, key, now, false);
    }

    fn insert_dummy_connection(connections: &mut Connections<u32, u32>) -> (u32, Index, PublicKey) {
        let conn = new_connection(12345, [1u8; 32]);
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
            .get_established_mut(&id, now)
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

    fn new_connection(idx: u32, key: [u8; 32]) -> Connection<u32> {
        let private = StaticSecret::random_from_rng(rand::thread_rng());
        let new_local = Index::new_local(idx);

        Connection {
            agent: IceAgent::new(),
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
            relay: SelectedRelay {
                id: 0,
                logged_sample_failure: false,
            },
            state: crate::node::ConnectionState::Connecting {
                wg_buffer: AllocRingBuffer::new(1),
                ip_buffer: AllocRingBuffer::new(1),
            },
            disconnected_at: None,
            stats: Default::default(),
            intent_sent_at: Instant::now(),
            signalling_completed_at: Instant::now(),
            first_handshake_completed_at: None,
            buffer: Default::default(),
            buffer_pool: BufferPool::new(0, "test"),
        }
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
}
