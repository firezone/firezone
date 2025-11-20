use std::{
    collections::{BTreeMap, btree_map::Entry},
    fmt,
    net::{IpAddr, SocketAddr},
    time::Instant,
};

use bufferpool::BufferPool;
use itertools::Itertools as _;
use rand::{Rng, seq::IteratorRandom as _};
use ringbuffer::{AllocRingBuffer, RingBuffer};
use str0m::Candidate;
use stun_codec::rfc5389::attributes::{Realm, Username};

use crate::{
    RelaySocket, Transmit,
    allocation::{self, Allocation},
    node::SessionId,
};

pub(crate) struct Allocations<RId> {
    inner: BTreeMap<RId, Allocation>,
    previous_relays_by_ip: AllocRingBuffer<IpAddr>,

    buffer_pool: BufferPool<Vec<u8>>,
}

impl<RId> Allocations<RId>
where
    RId: Ord + fmt::Display + Copy,
{
    pub(crate) fn clear(&mut self) {
        for (_, allocation) in std::mem::take(&mut self.inner) {
            self.previous_relays_by_ip
                .extend(server_addresses(&allocation));
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    pub(crate) fn contains(&self, id: &RId) -> bool {
        self.inner.contains_key(id)
    }

    pub(crate) fn get_by_id(&self, id: &RId) -> Option<&Allocation> {
        self.inner.get(id)
    }

    pub(crate) fn get_mut_by_id(&mut self, id: &RId) -> Option<&mut Allocation> {
        self.inner.get_mut(id)
    }

    pub(crate) fn get_mut_by_allocation(
        &mut self,
        addr: SocketAddr,
    ) -> Option<(RId, &mut Allocation)> {
        self.inner
            .iter_mut()
            .find_map(|(id, a)| a.has_socket(addr).then_some((*id, a)))
    }

    pub(crate) fn get_mut_by_server(&mut self, socket: SocketAddr) -> MutAllocationRef<'_, RId> {
        self.inner
            .iter_mut()
            .find_map(|(id, a)| a.server().matches(socket).then_some((*id, a)))
            .map(|(id, a)| MutAllocationRef::Connected(id, a))
            .or_else(|| {
                self.previous_relays_by_ip
                    .contains(&socket.ip())
                    .then_some(MutAllocationRef::Disconnected)
            })
            .unwrap_or(MutAllocationRef::Unknown)
    }

    pub(crate) fn candidates_for_relay(
        &self,
        id: &RId,
    ) -> impl Iterator<Item = Candidate> + use<RId> {
        let shared_candidates = self.shared_candidates();
        let relay_candidates = self
            .get_by_id(id)
            .into_iter()
            .flat_map(|allocation| allocation.current_relay_candidates());

        // Candidates with a higher priority are better, therefore: Reverse the ordering by priority.
        shared_candidates
            .chain(relay_candidates)
            .sorted_by_key(|c| c.prio())
            .rev()
    }

    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = (&RId, &mut Allocation)> {
        self.inner.iter_mut()
    }

    pub(crate) fn remove_by_id(&mut self, id: &RId) -> Option<Allocation> {
        let allocation = self.inner.remove(id)?;

        self.previous_relays_by_ip
            .extend(server_addresses(&allocation));

        Some(allocation)
    }

    pub(crate) fn upsert(
        &mut self,
        rid: RId,
        server: RelaySocket,
        username: Username,
        password: String,
        realm: Realm,
        now: Instant,
        session_id: SessionId,
    ) -> UpsertResult {
        match self.inner.entry(rid) {
            Entry::Vacant(v) => {
                v.insert(Allocation::new(
                    server,
                    username,
                    password,
                    realm,
                    now,
                    session_id,
                    self.buffer_pool.clone(),
                ));

                UpsertResult::Added
            }
            Entry::Occupied(mut o) => {
                let allocation = o.get();

                if allocation.matches_credentials(&username, &password)
                    && allocation.matches_socket(&server)
                {
                    return UpsertResult::Skipped;
                }

                let previous = o.insert(Allocation::new(
                    server,
                    username,
                    password,
                    realm,
                    now,
                    session_id,
                    self.buffer_pool.clone(),
                ));

                self.previous_relays_by_ip
                    .extend(server_addresses(&previous));

                UpsertResult::Replaced(previous)
            }
        }
    }

    pub(crate) fn sample(&self, rng: &mut impl Rng) -> Option<(RId, &Allocation)> {
        let (id, a) = self.inner.iter().choose(rng)?;

        Some((*id, a))
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        self.inner
            .values_mut()
            .filter_map(|a| a.poll_timeout())
            .min_by_key(|(t, _)| *t)
    }

    pub(crate) fn poll_event(&mut self) -> Option<(RId, allocation::Event)> {
        self.inner
            .iter_mut()
            .filter_map(|(id, a)| Some((*id, a.poll_event()?)))
            .next()
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        for allocation in self.inner.values_mut() {
            allocation.handle_timeout(now);
        }
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<Transmit> {
        self.inner
            .values_mut()
            .filter_map(Allocation::poll_transmit)
            .next()
    }

    pub(crate) fn gc(&mut self) {
        self.inner
            .retain(|rid, allocation| match allocation.can_be_freed() {
                Some(e) => {
                    tracing::info!(%rid, "Disconnecting from relay; {e}");

                    self.previous_relays_by_ip
                        .extend(server_addresses(allocation));

                    false
                }
                None => true,
            });
    }

    fn shared_candidates(&self) -> impl Iterator<Item = Candidate> {
        self.inner
            .values()
            .flat_map(|allocation| allocation.host_and_server_reflexive_candidates())
            .unique()
    }
}

pub(crate) enum MutAllocationRef<'a, RId> {
    Unknown,
    Disconnected,
    Connected(RId, &'a mut Allocation),
}

fn server_addresses(allocation: &Allocation) -> impl Iterator<Item = IpAddr> {
    std::iter::empty()
        .chain(
            allocation
                .server()
                .as_v4()
                .map(|s| s.ip())
                .copied()
                .map(IpAddr::from),
        )
        .chain(
            allocation
                .server()
                .as_v6()
                .map(|s| s.ip())
                .copied()
                .map(IpAddr::from),
        )
}

pub(crate) enum UpsertResult {
    Added,
    Skipped,
    Replaced(Allocation),
}

impl<RId> Default for Allocations<RId> {
    fn default() -> Self {
        Self {
            inner: Default::default(),
            previous_relays_by_ip: AllocRingBuffer::with_capacity_power_of_2(6), // 64 entries,
            buffer_pool: BufferPool::new(ip_packet::MAX_FZ_PAYLOAD, "turn-clients"),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use boringtun::x25519::PublicKey;

    use super::*;

    #[test]
    fn manual_remove_remembers_address() {
        let mut allocations = Allocations::default();
        allocations.upsert(
            1,
            RelaySocket::from(SERVER_V4),
            Username::new("test".to_owned()).unwrap(),
            "password".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            Instant::now(),
            SessionId::new(PublicKey::from([0u8; 32])),
        );

        allocations.remove_by_id(&1);

        assert!(matches!(
            allocations.get_mut_by_server(SERVER_V4),
            MutAllocationRef::Disconnected
        ));
    }

    #[test]
    fn clear_remembers_address() {
        let mut allocations = Allocations::default();
        allocations.upsert(
            1,
            RelaySocket::from(SERVER_V4),
            Username::new("test".to_owned()).unwrap(),
            "password".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            Instant::now(),
            SessionId::new(PublicKey::from([0u8; 32])),
        );

        allocations.clear();

        assert!(matches!(
            allocations.get_mut_by_server(SERVER_V4),
            MutAllocationRef::Disconnected
        ));
    }

    #[test]
    fn replace_by_address_remembers_address() {
        let mut allocations = Allocations::default();
        allocations.upsert(
            1,
            RelaySocket::from(SERVER_V4),
            Username::new("test".to_owned()).unwrap(),
            "password".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            Instant::now(),
            SessionId::new(PublicKey::from([0u8; 32])),
        );

        allocations.upsert(
            1,
            RelaySocket::from(SERVER2_V4),
            Username::new("test".to_owned()).unwrap(),
            "password".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            Instant::now(),
            SessionId::new(PublicKey::from([0u8; 32])),
        );

        assert!(matches!(
            allocations.get_mut_by_server(SERVER_V4),
            MutAllocationRef::Disconnected
        ));
    }

    const SERVER_V4: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 11111));
    const SERVER2_V4: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 22222));
}
