use std::{
    collections::{BTreeMap, btree_map::Entry},
    fmt,
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};

use bufferpool::BufferPool;
use is::Candidate;
use itertools::Itertools as _;
use rand::{Rng, seq::IteratorRandom as _};
use ringbuffer::{AllocRingBuffer, RingBuffer};
use smallvec::SmallVec;
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

    /// Sample an allocation for a new connection, biased towards low RTT.
    ///
    /// We compute an inclusion threshold from the observed RTT distribution
    /// (see [`inclusion_threshold`]) and uniformly sample among the relays at
    /// or below it. Allocations without an RTT measurement are skipped: we
    /// don't know whether they are healthy yet.
    pub(crate) fn sample(&self, rng: &mut impl Rng) -> Option<(RId, &Allocation)> {
        let candidates = self
            .inner
            .iter()
            .filter_map(|(id, a)| Some((*id, a, a.rtt()?)))
            .collect::<SmallVec<[_; 8]>>();

        let rtts = candidates
            .iter()
            .map(|(_, _, rtt)| *rtt)
            .collect::<SmallVec<[_; 8]>>();
        let threshold = inclusion_threshold(&rtts)?;

        candidates
            .iter()
            .filter(|(_, _, rtt)| *rtt <= threshold)
            .choose(rng)
            .map(|(id, a, _)| (*id, *a))
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

    /// Performs garbage-collection across all our allocations.
    ///
    /// Handling the resulting iterator is zero-cost if we end up not making any changes
    /// because we will simply end up returning an empty iterator.
    pub(crate) fn gc(&mut self) -> impl Iterator<Item = RId> + use<RId> {
        self.inner
            .extract_if(.., |rid, allocation| match allocation.can_be_freed() {
                Some(e) => {
                    tracing::info!(%rid, "Disconnecting from relay; {e}");

                    self.previous_relays_by_ip
                        .extend(server_addresses(allocation));

                    true
                }
                None => false,
            })
            .map(|(rid, _)| rid)
            .collect::<SmallVec<[_; 2]>>() // Typically, we are only connected to 2 relays. Using a `SmallVec` here avoids allocations.
            .into_iter()
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

/// Maximum RTT (inclusive) for a relay to be considered when sampling.
///
/// For 1-2 relays, MAD-based outlier detection degenerates (with two
/// samples the median sits exactly between them and MAD = gap/2, so neither is
/// ever an outlier). For those small-N cases we fall back to a relative
/// tolerance from the leader. For 3+ relays we use the standard `median + 3·MAD`
/// outlier rule, which adapts to whatever spread the data shows.
fn inclusion_threshold(rtts: &[Duration]) -> Option<Duration> {
    let min = rtts.iter().copied().min()?;

    if rtts.len() <= 2 {
        // Include relays within 1.5x of the leader.
        return Some(min * 3 / 2);
    }

    let mut sorted = rtts.iter().copied().collect::<SmallVec<[_; 8]>>();
    sorted.sort();
    let med = median(&sorted);

    let mut deviations = sorted
        .iter()
        .map(|r| r.abs_diff(med))
        .collect::<SmallVec<[_; 8]>>();
    deviations.sort();
    // Floor the MAD so that tightly-clustered relays don't collapse the
    // threshold to a sub-millisecond window. A relay that is only a few ms
    // slower than the leader should still be eligible.
    let mad = median(&deviations).max(MAD_FLOOR);

    Some(med + 3 * mad)
}

/// Minimum effective MAD used when computing the inclusion threshold.
const MAD_FLOOR: Duration = Duration::from_millis(2);

/// Median of a sorted slice.
///
/// For even-length slices, returns the average of the two middle elements.
fn median(sorted: &[Duration]) -> Duration {
    let n = sorted.len();

    if n.is_multiple_of(2) {
        (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    } else {
        sorted[n / 2]
    }
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
    use rand::SeedableRng as _;

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

    #[test]
    fn inclusion_threshold_falls_back_to_relative_for_small_n() {
        // n=1: just the single relay; threshold is 1.5x its RTT.
        assert_eq!(inclusion_threshold(&[ms(40)]), Some(ms(60)));

        // n=2: 1.5x of the leader.
        assert_eq!(inclusion_threshold(&[ms(40), ms(60)]), Some(ms(60)));
    }

    #[test]
    fn inclusion_threshold_uses_mad_for_three_or_more_relays() {
        // Tightly clustered: median=35, MAD=5, threshold=50; all kept.
        assert_eq!(inclusion_threshold(&[ms(30), ms(35), ms(40)]), Some(ms(50)));

        // One clear outlier: median=35, MAD=5, threshold=50; 200ms excluded.
        assert_eq!(
            inclusion_threshold(&[ms(30), ms(35), ms(200)]),
            Some(ms(50))
        );

        // Many fast + one slow: outlier identified.
        let threshold = inclusion_threshold(&[ms(30), ms(32), ms(35), ms(40), ms(200)]).unwrap();
        assert!(threshold < ms(100));
        assert!(threshold >= ms(40));
    }

    #[test]
    fn inclusion_threshold_floors_mad_so_tightly_clustered_relays_stay_in() {
        // sorted = [30, 30, 30, 31] ⇒ median = 30, deviations = [0, 0, 0, 1].
        // Raw MAD = 0, but the 2ms floor lifts the threshold to 30 + 3*2 = 36ms,
        // keeping the 31ms relay in the pool.
        assert_eq!(
            inclusion_threshold(&[ms(30), ms(30), ms(30), ms(31)]),
            Some(ms(36))
        );
    }

    #[test]
    fn inclusion_threshold_averages_two_middle_elements_for_even_n() {
        // n=4 sorted = [30, 40, 50, 60]
        // median = (40 + 50) / 2 = 45
        // deviations from 45 = [15, 5, 5, 15] sorted = [5, 5, 15, 15]
        // MAD = (5 + 15) / 2 = 10
        // threshold = 45 + 3 * 10 = 75
        assert_eq!(
            inclusion_threshold(&[ms(30), ms(40), ms(50), ms(60)]),
            Some(ms(75))
        );
    }

    #[test]
    fn sample_excludes_outlier_relay_among_many_fast_ones() {
        let now = Instant::now();
        let mut allocations = Allocations::default();

        for (rid, port, rtt_ms) in [
            (1u32, 11111u16, 30),
            (2, 22222, 32),
            (3, 33333, 35),
            (4, 44444, 40),
            (5, 55555, 200),
        ] {
            allocations.upsert(
                rid,
                RelaySocket::from(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)),
                Username::new("test".to_owned()).unwrap(),
                "password".to_owned(),
                Realm::new("firezone".to_owned()).unwrap(),
                now,
                SessionId::new(PublicKey::from([0u8; 32])),
            );
            allocations
                .get_mut_by_id(&rid)
                .unwrap()
                .set_rtt(Duration::from_millis(rtt_ms));
        }

        let mut rng = rand::rngs::StdRng::seed_from_u64(42);

        for _ in 0..1000 {
            let (rid, _) = allocations.sample(&mut rng).unwrap();
            assert_ne!(rid, 5, "outlier relay must not be selected");
        }
    }

    #[test]
    fn sample_distributes_load_across_similar_rtt_relays() {
        let now = Instant::now();
        let mut allocations = Allocations::default();

        // 1ms apart: both relays should be picked roughly equally (uniform within bucket).
        for (rid, port, rtt_ms) in [(1u32, 11111u16, 30), (2, 22222, 31)] {
            allocations.upsert(
                rid,
                RelaySocket::from(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)),
                Username::new("test".to_owned()).unwrap(),
                "password".to_owned(),
                Realm::new("firezone".to_owned()).unwrap(),
                now,
                SessionId::new(PublicKey::from([0u8; 32])),
            );
            allocations
                .get_mut_by_id(&rid)
                .unwrap()
                .set_rtt(Duration::from_millis(rtt_ms));
        }

        let mut rng = rand::rngs::StdRng::seed_from_u64(42);
        let mut counts = [0u32; 2];

        for _ in 0..10_000 {
            let (rid, _) = allocations.sample(&mut rng).unwrap();
            counts[(rid - 1) as usize] += 1;
        }

        let ratio = counts[0] as f64 / counts[1] as f64;
        assert!(
            (0.9..=1.1).contains(&ratio),
            "expected near-even split, got ratio {ratio}"
        );
    }

    #[test]
    fn sample_excludes_n2_relay_when_much_slower() {
        let now = Instant::now();
        let mut allocations = Allocations::default();

        // 30ms vs 200ms with n=2 ⇒ 200ms is 6.7x the leader, well outside 1.5x.
        for (rid, port, rtt_ms) in [(1u32, 11111u16, 30), (2, 22222, 200)] {
            allocations.upsert(
                rid,
                RelaySocket::from(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)),
                Username::new("test".to_owned()).unwrap(),
                "password".to_owned(),
                Realm::new("firezone".to_owned()).unwrap(),
                now,
                SessionId::new(PublicKey::from([0u8; 32])),
            );
            allocations
                .get_mut_by_id(&rid)
                .unwrap()
                .set_rtt(Duration::from_millis(rtt_ms));
        }

        let mut rng = rand::rngs::StdRng::seed_from_u64(42);

        for _ in 0..100 {
            let (rid, _) = allocations.sample(&mut rng).unwrap();
            assert_eq!(rid, 1);
        }
    }

    #[test]
    fn sample_falls_back_to_only_remaining_relay_even_if_high_rtt() {
        let now = Instant::now();
        let mut allocations = Allocations::default();

        allocations.upsert(
            1,
            RelaySocket::from(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 11111)),
            Username::new("test".to_owned()).unwrap(),
            "password".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            now,
            SessionId::new(PublicKey::from([0u8; 32])),
        );
        allocations
            .get_mut_by_id(&1)
            .unwrap()
            .set_rtt(Duration::from_millis(500));

        let mut rng = rand::rngs::StdRng::seed_from_u64(42);

        let (rid, _) = allocations.sample(&mut rng).unwrap();
        assert_eq!(rid, 1);
    }

    #[test]
    fn sample_excludes_allocations_without_rtt() {
        let now = Instant::now();
        let mut allocations = Allocations::default();

        allocations.upsert(
            1,
            RelaySocket::from(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 11111)),
            Username::new("test".to_owned()).unwrap(),
            "password".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            now,
            SessionId::new(PublicKey::from([0u8; 32])),
        );

        let mut rng = rand::rngs::StdRng::seed_from_u64(42);

        assert_eq!(allocations.get_by_id(&1).unwrap().rtt(), None);
        assert!(allocations.sample(&mut rng).is_none());
    }

    const SERVER_V4: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 11111));
    const SERVER2_V4: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 22222));

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }
}
