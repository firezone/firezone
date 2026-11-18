use std::hash::{DefaultHasher, Hash, Hasher};
use std::net::IpAddr;

/// Distinct addresses a generation holds before it is rotated out.
const CAPACITY: usize = 4096;
/// Bits per generation, sized for about 1% false positives at [`CAPACITY`] with [`NUM_HASHES`] hash functions.
const NUM_BITS: usize = 40_960;
const NUM_HASHES: u64 = 7;

/// The peer addresses the portal reported for one account.
///
/// Addresses live in two generations of bloom filters.
/// Once `current` has seen [`CAPACITY`] distinct addresses, it becomes `previous` and a fresh filter takes its place.
/// An address is thus forgotten only after [`CAPACITY`] further distinct inserts, which bounds both memory and the false-positive rate regardless of how many addresses an account churns through.
#[derive(Debug, Default)]
pub struct KnownPeers {
    current: BloomFilter,
    previous: BloomFilter,
}

impl KnownPeers {
    pub fn insert(&mut self, ip: IpAddr) {
        if !self.current.insert(ip) {
            return;
        }

        if self.current.num_inserted >= CAPACITY {
            self.previous = std::mem::take(&mut self.current);
        }
    }

    pub fn contains(&self, ip: IpAddr) -> bool {
        self.current.contains(ip) || self.previous.contains(ip)
    }
}

#[derive(Debug)]
struct BloomFilter {
    bits: Box<[u64]>,
    num_inserted: usize,
}

impl Default for BloomFilter {
    fn default() -> Self {
        Self {
            bits: vec![0; NUM_BITS.div_ceil(64)].into_boxed_slice(),
            num_inserted: 0,
        }
    }
}

impl BloomFilter {
    /// Inserts an address and returns whether it was not yet contained.
    fn insert(&mut self, ip: IpAddr) -> bool {
        let mut is_new = false;

        for bit in bit_indices(ip) {
            let (word, mask) = (bit / 64, 1 << (bit % 64));

            if self.bits[word] & mask == 0 {
                self.bits[word] |= mask;
                is_new = true;
            }
        }

        if is_new {
            self.num_inserted += 1;
        }

        is_new
    }

    fn contains(&self, ip: IpAddr) -> bool {
        bit_indices(ip).all(|bit| self.bits[bit / 64] & (1 << (bit % 64)) != 0)
    }
}

/// Derives [`NUM_HASHES`] bit positions from one 64-bit hash via Kirsch-Mitzenmacher double hashing.
fn bit_indices(ip: IpAddr) -> impl Iterator<Item = usize> {
    let mut hasher = DefaultHasher::new();
    ip.hash(&mut hasher);
    let hash = hasher.finish();

    let h1 = hash & u32::MAX as u64;
    let h2 = (hash >> 32) | 1;

    (0..NUM_HASHES).map(move |i| ((h1 + i * h2) % NUM_BITS as u64) as usize)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::{RngExt as _, SeedableRng as _, rngs::StdRng};
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn inserted_addresses_are_contained() {
        let mut peers = KnownPeers::default();
        let v4 = IpAddr::from(Ipv4Addr::new(203, 0, 113, 7));
        let v6 = IpAddr::from(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1));

        peers.insert(v4);
        peers.insert(v6);

        assert!(peers.contains(v4));
        assert!(peers.contains(v6));
        assert!(!peers.contains(IpAddr::from(Ipv4Addr::new(203, 0, 113, 8))));
    }

    #[test]
    fn false_positive_rate_at_capacity_stays_below_two_percent() {
        let mut peers = KnownPeers::default();
        let mut rng = StdRng::seed_from_u64(0);
        fill(&mut peers, &mut rng, CAPACITY);

        let num_probes = 10_000;
        let false_positives = (0..num_probes)
            .filter(|_| peers.contains(IpAddr::from(Ipv6Addr::from(rng.random::<u128>()))))
            .count();

        assert!(
            false_positives < num_probes / 50,
            "{false_positives} false positives out of {num_probes}"
        );
    }

    #[test]
    fn rotation_keeps_previous_generation() {
        let mut peers = KnownPeers::default();
        let mut rng = StdRng::seed_from_u64(0);
        let ip = IpAddr::from(Ipv4Addr::new(203, 0, 113, 7));

        peers.insert(ip);
        fill(&mut peers, &mut rng, CAPACITY + CAPACITY / 2);

        assert!(peers.contains(ip));
    }

    #[test]
    fn rotation_forgets_addresses_two_generations_old() {
        let mut peers = KnownPeers::default();
        let mut rng = StdRng::seed_from_u64(0);
        let ip = IpAddr::from(Ipv4Addr::new(203, 0, 113, 7));

        peers.insert(ip);
        fill(&mut peers, &mut rng, 3 * CAPACITY);

        assert!(!peers.contains(ip));
    }

    #[test]
    fn reinserting_keeps_address_across_rotations() {
        let mut peers = KnownPeers::default();
        let mut rng = StdRng::seed_from_u64(0);
        let ip = IpAddr::from(Ipv4Addr::new(203, 0, 113, 7));

        peers.insert(ip);
        fill(&mut peers, &mut rng, CAPACITY + CAPACITY / 2);
        peers.insert(ip);
        fill(&mut peers, &mut rng, CAPACITY + CAPACITY / 2);

        assert!(peers.contains(ip));
    }

    /// Inserts `count` random IPv4 addresses from `10.0.0.0/8`.
    fn fill(peers: &mut KnownPeers, rng: &mut StdRng, count: usize) {
        for _ in 0..count {
            let host = rng.random::<u32>() & 0x00FF_FFFF;
            peers.insert(IpAddr::from(Ipv4Addr::from(
                u32::from(Ipv4Addr::new(10, 0, 0, 0)) | host,
            )));
        }
    }
}
