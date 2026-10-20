use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    fmt,
    hash::Hash,
    iter,
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, bail};
use fast_random_state::FastRandomState;
use ip_packet::IpPacket;
use is::stun::{StunMessage, TransId};

use crate::{
    EncryptJob, Event,
    node::{
        Connection, ConnectionState, Transmit, allocations::Allocations,
        inflight_stun_requests::InflightStunRequests,
    },
};

/// How long a closed connection waits until it can encrypt its goodbye; matches WireGuard's handshake timeout.
const GOODBYE_TIMEOUT: Duration = Duration::from_secs(5);

pub struct Connections<TId, RId> {
    slots: Vec<Option<Entry<TId, RId>>>,
    free_slots: Vec<usize>,

    by_id: BTreeMap<TId, usize>,
    by_tunnel_id: HashMap<sanstun::TunnelId, usize, FastRandomState>,
    by_local_ufrag: BTreeMap<String, usize>,

    disconnected_ids: BTreeMap<TId, Instant>,
    disconnected_public_keys: BTreeMap<[u8; 32], Instant>,
    disconnected_tunnel_ids: HashMap<sanstun::TunnelId, Instant, FastRandomState>,
    disconnected_ufrags: BTreeMap<String, Instant>,
}

struct Entry<TId, RId> {
    id: TId,
    connection: Connection<RId>,
    /// Set once the connection is closed and waits to send its goodbye.
    goodbye: Option<Goodbye>,
}

impl<TId, RId> Default for Connections<TId, RId> {
    fn default() -> Self {
        Self {
            slots: Default::default(),
            free_slots: Default::default(),
            by_id: Default::default(),
            by_tunnel_id: Default::default(),
            by_local_ufrag: Default::default(),
            disconnected_ids: Default::default(),
            disconnected_public_keys: Default::default(),
            disconnected_tunnel_ids: Default::default(),
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

    pub(crate) fn remove_established(&mut self, id: &TId, now: Instant) -> Option<Connection<RId>> {
        let slot = *self.by_id.get(id)?;
        let removed = self.remove_slot(slot, now)?;

        Some(removed.connection)
    }

    /// Closes the connection to `id` and sends `goodbye` to the peer.
    pub(crate) fn close(&mut self, id: TId, goodbye: IpPacket, now: Instant) -> Result<()> {
        let entry = self
            .by_id
            .get(&id)
            .and_then(|&slot| self.slots.get_mut(slot)?.as_mut())
            .filter(|entry| entry.goodbye.is_none())
            .context("Cannot close unknown connection")?;

        tracing::debug!("Connection closed proactively (goodbye pending)");

        entry.goodbye = Some(Goodbye {
            packet: goodbye,
            deadline: now + GOODBYE_TIMEOUT,
        });

        Ok(())
    }

    pub(crate) fn remove_closing(
        &mut self,
        filter: impl Fn(&Connection<RId>) -> bool,
        now: Instant,
    ) {
        self.remove_where(
            |entry| entry.goodbye.is_some() && filter(&entry.connection),
            now,
        );
    }

    pub(crate) fn handle_timeout(
        &mut self,
        allocations: &mut Allocations<RId>,
        transmits: &mut VecDeque<Transmit>,
        encrypt_jobs: &mut VecDeque<EncryptJob>,
        events: &mut VecDeque<Event<TId, RId>>,
        inflight_stun_requests: &mut InflightStunRequests<TId>,
        now: Instant,
    ) {
        for (cid, connection) in self.iter_mut() {
            if connection.relay.is_none() {
                connection.assign_relay(cid, allocations, events, now);
            }

            connection.handle_timeout(
                cid,
                now,
                allocations,
                transmits,
                encrypt_jobs,
                events,
                inflight_stun_requests,
            );
        }

        for (cid, connection, goodbye) in self.iter_closing_mut() {
            if now >= goodbye.deadline {
                tracing::debug!(id = %cid, state = %connection.state, index = ?connection.tunnel.id(), "Connection closed proactively (failed to send goodbye in time)");
                connection.state = ConnectionState::Failed;
                continue;
            }

            connection.handle_timeout(
                cid,
                now,
                allocations,
                transmits,
                encrypt_jobs,
                &mut VecDeque::new(),
                inflight_stun_requests,
            );

            let Ok(socket) = connection.ready_socket(cid) else {
                continue;
            };

            match connection.encapsulate(cid, socket, &goodbye.packet, now, allocations) {
                Ok(Some(encapsulation)) => {
                    encrypt_jobs.push_back(encapsulation.into_job(goodbye.packet.clone()));
                    tracing::info!(%cid, "Connection closed proactively (sent goodbye)");
                }
                Ok(None) => {
                    tracing::debug!(%cid, "Connection closed proactively (failed to send goodbye)");
                }
                Err(e) => {
                    tracing::debug!(%cid, "Connection closed proactively (failed to send goodbye: {e:#})");
                }
            }

            connection.state = ConnectionState::Failed;
        }

        self.remove_failed(events, now);
    }

    /// Soft-resets all connections for a roam.
    ///
    /// The roam restarts all allocations, so every connection waits for a relay again.
    pub(crate) fn reset_for_roam(&mut self, now: Instant) -> usize {
        let mut num_connections = 0;

        for (cid, conn) in self.iter_mut() {
            conn.reset_for_roam(now);
            conn.clear_relay(cid);

            num_connections += 1;
        }

        num_connections
    }

    pub(crate) fn clear_relays(&mut self, removed_allocations: impl Iterator<Item = RId>) {
        for removed_relay in removed_allocations {
            for (cid, c) in self.iter_mut_by_relay(removed_relay) {
                c.clear_relay(cid);
            }
        }
    }

    pub(crate) fn insert_established(&mut self, id: TId, connection: Connection<RId>) {
        if let Some(&previous) = self.by_id.get(&id) {
            self.free_slot(previous);
        }

        let tunnel_id = connection.tunnel.id();
        let local_ufrag = connection.agent.local_ufrag().map(ToOwned::to_owned);
        let entry = Entry {
            id,
            connection,
            goodbye: None,
        };

        let slot = match self.free_slots.pop() {
            Some(slot) => {
                self.slots[slot] = Some(entry);

                slot
            }
            None => {
                self.slots.push(Some(entry));

                self.slots.len() - 1
            }
        };

        self.by_id.insert(id, slot);
        self.by_tunnel_id.insert(tunnel_id, slot);
        if let Some(ufrag) = local_ufrag {
            self.by_local_ufrag.insert(ufrag, slot);
        }
    }

    pub(crate) fn iter_mut_by_relay(
        &mut self,
        id: RId,
    ) -> impl Iterator<Item = (TId, &mut Connection<RId>)> + '_ {
        self.iter_mut().filter(move |(_, c)| c.relay == Some(id))
    }

    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = (TId, &mut Connection<RId>)> {
        self.iter_slots_mut().filter_map(|(_, entry)| {
            entry
                .goodbye
                .is_none()
                .then_some((entry.id, &mut entry.connection))
        })
    }

    pub(crate) fn get_mut(&mut self, id: &TId, now: Instant) -> Result<&mut Connection<RId>> {
        let entry = self
            .by_id
            .get(id)
            .and_then(|&slot| self.slots.get_mut(slot)?.as_mut())
            .filter(|entry| entry.goodbye.is_none())
            .with_context(|| UnknownConnection::by_id(*id, &self.disconnected_ids, now))?;

        Ok(&mut entry.connection)
    }

    pub(crate) fn get_established(&self, id: &TId) -> Option<&Connection<RId>> {
        let entry = self
            .by_id
            .get(id)
            .and_then(|&slot| self.slots.get(slot)?.as_ref())
            .filter(|entry| entry.goodbye.is_none())?;

        Some(&entry.connection)
    }

    /// Returns the connection in `slot` if it still has the tunnel ID `tunnel_id`.
    pub(crate) fn get_mut_by_slot(
        &mut self,
        slot: usize,
        tunnel_id: sanstun::TunnelId,
        now: Instant,
    ) -> Result<(TId, &mut Connection<RId>)> {
        let entry = self
            .slots
            .get_mut(slot)
            .and_then(Option::as_mut)
            .filter(|entry| entry.connection.tunnel.id() == tunnel_id)
            .with_context(|| {
                UnknownConnection::by_tunnel_id(tunnel_id, &self.disconnected_tunnel_ids, now)
            })?;

        Ok((entry.id, &mut entry.connection))
    }

    pub(crate) fn get_established_mut_by_tunnel_id(
        &mut self,
        tunnel_id: sanstun::TunnelId,
        now: Instant,
    ) -> Result<(TId, usize, &mut Connection<RId>)> {
        let (slot, entry) = self
            .by_tunnel_id
            .get(&tunnel_id)
            .and_then(|&slot| Some((slot, self.slots.get_mut(slot)?.as_mut()?)))
            .with_context(|| {
                UnknownConnection::by_tunnel_id(tunnel_id, &self.disconnected_tunnel_ids, now)
            })?;

        Ok((entry.id, slot, &mut entry.connection))
    }

    pub(crate) fn get_established_mut_by_public_key(
        &mut self,
        key: [u8; 32],
        now: Instant,
    ) -> Result<(TId, usize, &mut Connection<RId>)> {
        // An established connection takes precedence over a closing one with the same key.
        let (slot, entry) = self
            .iter_slots()
            .filter(|(_, entry)| entry.connection.tunnel.remote_static_public().as_bytes() == &key)
            .min_by_key(|(_, entry)| entry.goodbye.is_some())
            .map(|(slot, _)| slot)
            .and_then(|slot| Some((slot, self.slots.get_mut(slot)?.as_mut()?)))
            .with_context(|| {
                UnknownConnection::by_public_key(key, &self.disconnected_public_keys, now)
            })?;

        Ok((entry.id, slot, &mut entry.connection))
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
            let entry = self
                .by_local_ufrag
                .get(ufrag)
                .and_then(|&slot| self.slots.get_mut(slot)?.as_mut())
                .ok_or(UnknownConnection::by_local_ufrag(
                    ufrag,
                    &self.disconnected_ufrags,
                    now,
                ))?;

            return Ok((entry.id, &mut entry.connection));
        }

        if message.is_successful_binding_response() {
            let trans_id = message.trans_id();
            let id = inflight_stun_requests
                .remove(trans_id)
                .ok_or(UnknownConnection::by_trans_id(trans_id))?;
            let conn = self.get_mut_including_closing(&id, now)?;

            return Ok((id, conn));
        }

        bail!("STUN message is not a BINDING")
    }

    fn get_mut_including_closing(
        &mut self,
        id: &TId,
        now: Instant,
    ) -> Result<&mut Connection<RId>> {
        let entry = self
            .by_id
            .get(id)
            .and_then(|&slot| self.slots.get_mut(slot)?.as_mut())
            .with_context(|| UnknownConnection::by_id(*id, &self.disconnected_ids, now))?;

        Ok(&mut entry.connection)
    }

    pub(crate) fn is_closing(&self, slot: usize) -> bool {
        self.slots
            .get(slot)
            .and_then(Option::as_ref)
            .is_some_and(|entry| entry.goodbye.is_some())
    }

    pub(crate) fn iter_established(&self) -> impl Iterator<Item = (TId, &Connection<RId>)> {
        self.iter_slots().filter_map(|(_, entry)| {
            entry
                .goodbye
                .is_none()
                .then_some((entry.id, &entry.connection))
        })
    }

    pub(crate) fn len(&self) -> usize {
        self.iter_established().count()
    }

    pub(crate) fn is_connected(&self, id: &TId) -> bool {
        self.get_established(id)
            .is_some_and(Connection::is_connected)
    }

    pub(crate) fn clear(&mut self) {
        self.slots.clear();
        self.free_slots.clear();
        self.by_id.clear();
        self.by_tunnel_id.clear();
        self.by_local_ufrag.clear();
    }

    pub(crate) fn iter_ids(&self) -> impl Iterator<Item = TId> + '_ {
        self.iter_established().map(|(id, _)| id)
    }

    pub(crate) fn all_iceless(&self) -> bool {
        self.len() > 0 && self.iter_established().all(|(_, c)| c.agent.is_iceless())
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "The earliest disconnect is the same in any iteration order."
    )]
    pub(crate) fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            .chain(self.slots.iter_mut().flatten().flat_map(|entry| {
                let goodbye = entry.goodbye.as_ref().map(|goodbye| {
                    let ready_at = entry
                        .connection
                        .first_handshake_completed_at
                        .filter(|_| entry.connection.ready_socket(entry.id).is_ok());

                    iter::once((goodbye.deadline, "goodbye timeout"))
                        .chain(ready_at.map(|t| (t, "goodbye ready")))
                });

                goodbye
                    .into_iter()
                    .flatten()
                    .chain(entry.connection.poll_timeout())
            }))
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
                self.disconnected_tunnel_ids
                    .values()
                    .map(|t| {
                        (
                            *t + Self::RECENT_DISCONNECT_TIMEOUT,
                            "recently disconnected tunnel ids",
                        )
                    })
                    .min_by_key(|(t, _)| *t),
            )
            .min_by_key(|(instant, _)| *instant)
    }

    fn remove_failed(&mut self, events: &mut VecDeque<Event<TId, RId>>, now: Instant) {
        self.remove_closing(Connection::is_failed, now);

        for removed in self.remove_where(
            |entry| entry.goodbye.is_none() && entry.connection.is_failed(),
            now,
        ) {
            events.push_back(Event::ConnectionFailed(removed.id));
        }

        self.disconnected_ids
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
        self.disconnected_public_keys
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
        self.disconnected_tunnel_ids
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
        self.disconnected_ufrags
            .retain(|_, v| now.duration_since(*v) < Self::RECENT_DISCONNECT_TIMEOUT);
    }

    /// Removes all connections matching `filter`, in `TId` order.
    fn remove_where(
        &mut self,
        filter: impl Fn(&Entry<TId, RId>) -> bool,
        now: Instant,
    ) -> Vec<Entry<TId, RId>> {
        let slots = self
            .iter_slots()
            .filter(|(_, entry)| filter(entry))
            .map(|(slot, _)| slot)
            .collect::<Vec<_>>();

        slots
            .into_iter()
            .filter_map(|slot| self.remove_slot(slot, now))
            .collect()
    }

    fn remove_slot(&mut self, slot: usize, now: Instant) -> Option<Entry<TId, RId>> {
        let removed = self.free_slot(slot)?;
        let connection = &removed.connection;

        self.disconnected_ids.insert(removed.id, now);
        self.disconnected_public_keys
            .insert(connection.tunnel.remote_static_public().to_bytes(), now);
        self.disconnected_tunnel_ids
            .insert(connection.tunnel.id(), now);
        if let Some(ufrag) = connection.agent.local_ufrag() {
            self.disconnected_ufrags.insert(ufrag.to_owned(), now);
        }

        Some(removed)
    }

    fn free_slot(&mut self, slot: usize) -> Option<Entry<TId, RId>> {
        let removed = self.slots.get_mut(slot)?.take()?;
        self.free_slots.push(slot);

        self.by_id.remove(&removed.id);
        self.by_tunnel_id.remove(&removed.connection.tunnel.id());
        if let Some(ufrag) = removed.connection.agent.local_ufrag() {
            self.by_local_ufrag.remove(ufrag);
        }

        Some(removed)
    }

    fn iter_closing_mut(
        &mut self,
    ) -> impl Iterator<Item = (TId, &mut Connection<RId>, &mut Goodbye)> {
        self.iter_slots_mut().filter_map(|(_, entry)| {
            let goodbye = entry.goodbye.as_mut()?;

            Some((entry.id, &mut entry.connection, goodbye))
        })
    }

    fn iter_slots(&self) -> impl Iterator<Item = (usize, &Entry<TId, RId>)> {
        self.by_id
            .values()
            .filter_map(|&slot| Some((slot, self.slots.get(slot)?.as_ref()?)))
    }

    /// Iterates over all occupied slots in `TId` order.
    fn iter_slots_mut(&mut self) -> impl Iterator<Item = (usize, &mut Entry<TId, RId>)> {
        // The index visits the table out of order, so every slot is split into its own borrow up front.
        let mut slots = self
            .slots
            .iter_mut()
            .map(Option::as_mut)
            .collect::<Vec<_>>();

        self.by_id
            .values()
            .filter_map(move |&slot| Some((slot, slots.get_mut(slot)?.take()?)))
    }
}

#[derive(Debug)]
struct Goodbye {
    packet: IpPacket,
    deadline: Instant,
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

    fn by_tunnel_id(
        id: sanstun::TunnelId,
        disconnected_tunnel_ids: &HashMap<sanstun::TunnelId, Instant, FastRandomState>,
        now: Instant,
    ) -> Self {
        Self {
            id: format!("{id:?}"),
            kind: "tunnel id",
            disconnected_for: disconnected_tunnel_ids
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
    use is::IceAgent;
    use rand::random;
    use ringbuffer::AllocRingBuffer;
    use zeroize::Zeroizing;

    use std::net::{Ipv4Addr, SocketAddrV4};

    use crate::{
        IceConfig, RelaySocket,
        node::{ConnectionState, allocations::Allocations},
    };
    use stun_codec::rfc5389::attributes::{Realm, Username};

    use super::*;

    #[test]
    fn explicitly_removed_connection() {
        let mut connections = Connections::default();
        let mut now = Instant::now();

        let (id, idx, key) = insert_dummy_connection(&mut connections);

        connections.remove_established(&id, now);
        handle_timeout(&mut connections, now);

        now += Duration::from_secs(1);

        assert_disconnected(&mut connections, id, idx, key, now, true);

        now += Duration::from_secs(5);
        handle_timeout(&mut connections, now);

        assert_disconnected(&mut connections, id, idx, key, now, false);
    }

    #[test]
    fn failed_connection() {
        let mut connections = Connections::default();
        let mut now = Instant::now();

        let (id, idx, key) = insert_dummy_connection(&mut connections);

        connections.get_mut(&id, now).unwrap().state = ConnectionState::Failed;
        handle_timeout(&mut connections, now);
        now += Duration::from_secs(1);

        assert_disconnected(&mut connections, id, idx, key, now, true);

        now += Duration::from_secs(5);
        handle_timeout(&mut connections, now);

        assert_disconnected(&mut connections, id, idx, key, now, false);
    }

    #[test]
    #[expect(clippy::disallowed_methods, reason = "This is a test.")]
    fn reused_slot_rejects_stale_tunnel_id() {
        let mut connections = Connections::default();
        let now = Instant::now();
        let (id, idx, _) = insert_dummy_connection(&mut connections);
        let (_, slot, _) = connections
            .get_established_mut_by_tunnel_id(idx, now)
            .unwrap();

        connections.remove_established(&id, now);
        connections.insert_established(2, new_connection(None, [2u8; 32]));

        let (_, new_slot, _) = connections
            .get_established_mut_by_public_key([2u8; 32], now)
            .unwrap();
        assert_eq!(new_slot, slot);
        let err = connections
            .get_mut_by_slot(slot, idx, now)
            .unwrap_err()
            .downcast::<UnknownConnection>()
            .unwrap();
        assert!(err.recently_disconnected());
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
    fn connection_without_relay_gets_one_once_available() {
        let mut connections: Connections<u32, u32> = Connections::default();
        let mut allocations: Allocations<u32> = Allocations::for_test();
        let now = Instant::now();

        let conn = new_connection(Some(1), [1u8; 32]);
        connections.insert_established(1, conn);

        connections.clear_relays(std::iter::once(1u32));

        assert_eq!(connections.get_mut(&1, now).unwrap().relay, None);

        add_sampleable_allocation(&mut allocations, 2, now);
        handle_timeout_with_allocations(&mut connections, &mut allocations, now);

        assert_eq!(connections.get_mut(&1, now).unwrap().relay, Some(2));
    }

    #[test]
    fn roam_reset_makes_connections_wait_for_a_relay() {
        // The portal may hand out relays under new IDs after a roam; connections
        // must not stay pinned to relays that no longer exist.
        let mut connections: Connections<u32, u32> = Connections::default();
        let mut allocations: Allocations<u32> = Allocations::for_test();
        let now = Instant::now();

        let mut conn = new_connection(Some(1), [1u8; 32]);
        conn.agent = crate::agent::Agent::path();
        connections.insert_established(1, conn);

        connections.reset_for_roam(now);

        assert_eq!(connections.get_mut(&1, now).unwrap().relay, None);

        add_sampleable_allocation(&mut allocations, 2, now);
        handle_timeout_with_allocations(&mut connections, &mut allocations, now);

        assert_eq!(connections.get_mut(&1, now).unwrap().relay, Some(2));
    }

    fn add_sampleable_allocation(allocations: &mut Allocations<u32>, rid: u32, now: Instant) {
        allocations.upsert(
            rid,
            RelaySocket::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 3478 + rid as u16)),
            Username::new("user".to_owned()).unwrap(),
            "pass".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            now,
        );
        // Simulate a successful response so the relay is eligible for sampling.
        allocations
            .get_mut_by_id(&rid)
            .unwrap()
            .set_rtt(Duration::from_millis(20));
    }

    fn handle_timeout(connections: &mut Connections<u32, u32>, now: Instant) {
        handle_timeout_with_allocations(connections, &mut Allocations::for_test(), now);
    }

    fn handle_timeout_with_allocations(
        connections: &mut Connections<u32, u32>,
        allocations: &mut Allocations<u32>,
        now: Instant,
    ) {
        connections.handle_timeout(
            allocations,
            &mut VecDeque::new(),
            &mut VecDeque::new(),
            &mut VecDeque::default(),
            &mut InflightStunRequests::default(),
            now,
        );
    }

    fn insert_dummy_connection(
        connections: &mut Connections<u32, u32>,
    ) -> (u32, sanstun::TunnelId, sanstun::PublicKey) {
        let conn = new_connection(Some(0), [1u8; 32]);
        let id = 1;
        let idx = conn.tunnel.id();
        let key = conn.tunnel.remote_static_public();
        connections.insert_established(id, conn);

        (id, idx, key)
    }

    #[expect(clippy::disallowed_methods, reason = "This is a test.")]
    fn assert_disconnected(
        connections: &mut Connections<u32, u32>,
        id: u32,
        idx: sanstun::TunnelId,
        key: sanstun::PublicKey,
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
            .get_established_mut_by_tunnel_id(idx, now)
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

    fn new_connection(relay: Option<u32>, key: [u8; 32]) -> Connection<u32> {
        let tunnel =
            sanstun::Interface::new(Zeroizing::new(random()), Instant::now(), Duration::ZERO)
                .new_tunnel(
                    sanstun::PublicKey::from(key),
                    sanstun::TunnelConfig::default(),
                    Instant::now(),
                )
                .unwrap();

        Connection {
            agent: crate::agent::Agent::ice(IceAgent::new(is::IceCreds::new())),
            tunnel,
            preshared_key: sanstun::StaticSecret::from(Zeroizing::new([0; 32])),
            remote_pub_key: sanstun::PublicKey::from(rand::random::<[u8; 32]>()),
            last_proactive_handshake_sent_at: None,
            relay,
            state: crate::node::ConnectionState::Connecting {
                wg_buffer: AllocRingBuffer::new(1),
            },
            disconnected_at: None,
            intent_sent_at: Instant::now(),
            candidate_timeout: None,
            first_handshake_completed_at: None,
            default_ice_config: IceConfig::client_default(),
            idle_ice_config: IceConfig::client_idle(),
            poll_timeout_cache: Default::default(),
        }
    }
}
