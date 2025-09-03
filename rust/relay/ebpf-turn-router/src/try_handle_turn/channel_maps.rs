//! Houses all combinations of IPv4 <> IPv6 and Channel <> UDP mappings.
//!
//! Testing has shown that these maps are safe to use as long as we aren't
//! writing to them from multiple threads at the same time. Since we only update these
//! from the single-threaded eventloop in userspace, we are ok.
//! See https://github.com/firezone/firezone/issues/10138#issuecomment-3186074350

use aya_ebpf::{macros::map, maps::HashMap};
use ebpf_shared::{ClientAndChannelV4, ClientAndChannelV6, PortAndPeerV4, PortAndPeerV6};

const NUM_ENTRIES: u32 = 0x10000;

#[map]
pub static CHAN_TO_UDP_44: HashMap<ClientAndChannelV4, PortAndPeerV4> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
pub static UDP_TO_CHAN_44: HashMap<PortAndPeerV4, ClientAndChannelV4> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
pub static CHAN_TO_UDP_66: HashMap<ClientAndChannelV6, PortAndPeerV6> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
pub static UDP_TO_CHAN_66: HashMap<PortAndPeerV6, ClientAndChannelV6> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
pub static CHAN_TO_UDP_46: HashMap<ClientAndChannelV4, PortAndPeerV6> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
pub static UDP_TO_CHAN_46: HashMap<PortAndPeerV4, ClientAndChannelV6> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
pub static CHAN_TO_UDP_64: HashMap<ClientAndChannelV6, PortAndPeerV4> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
pub static UDP_TO_CHAN_64: HashMap<PortAndPeerV6, ClientAndChannelV4> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);

#[cfg(test)]
mod tests {
    use super::*;

    /// Memory overhead of an eBPF map.
    ///
    /// Determined empirically.
    const HASH_MAP_OVERHEAD: f32 = 1.5;

    #[test]
    fn hashmaps_are_less_than_11_mb() {
        let ipv4_datatypes =
            core::mem::size_of::<PortAndPeerV4>() + core::mem::size_of::<ClientAndChannelV4>();
        let ipv6_datatypes =
            core::mem::size_of::<PortAndPeerV6>() + core::mem::size_of::<ClientAndChannelV6>();

        let ipv4_map_size = ipv4_datatypes as f32 * NUM_ENTRIES as f32 * HASH_MAP_OVERHEAD;
        let ipv6_map_size = ipv6_datatypes as f32 * NUM_ENTRIES as f32 * HASH_MAP_OVERHEAD;

        let total_map_size = (ipv4_map_size + ipv6_map_size) * 2_f32;
        let total_map_size_mb = total_map_size / 1024_f32 / 1024_f32;

        assert!(
            total_map_size_mb < 11_f32,
            "Total map size = {total_map_size_mb} MB"
        );
    }
}
