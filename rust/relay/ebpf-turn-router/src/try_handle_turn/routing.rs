//! Houses all combinations of IPv4 <> IPv6 and Channel <> UDP mappings.
//!
//! Testing has shown that these maps are safe to use as long as we aren't
//! writing to them from multiple threads at the same time. Since we only update these
//! from the single-threaded eventloop in userspace, we are ok.
//! See <https://github.com/firezone/firezone/issues/10138#issuecomment-3186074350>.

use aya_ebpf::{macros::map, maps::HashMap};
use ebpf_shared::{
    ClientAndChannel, ClientAndChannelV4, ClientAndChannelV6, PortAndPeer, PortAndPeerV4,
    PortAndPeerV6,
};

use crate::try_handle_turn::Error;

use super::error::SupportedChannel;

const NUM_ENTRIES: u32 = 0x10000;

#[map]
static CHAN_TO_UDP_44: HashMap<ClientAndChannelV4, PortAndPeerV4> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static UDP_TO_CHAN_44: HashMap<PortAndPeerV4, ClientAndChannelV4> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static CHAN_TO_UDP_66: HashMap<ClientAndChannelV6, PortAndPeerV6> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static UDP_TO_CHAN_66: HashMap<PortAndPeerV6, ClientAndChannelV6> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static CHAN_TO_UDP_46: HashMap<ClientAndChannelV4, PortAndPeerV6> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static UDP_TO_CHAN_46: HashMap<PortAndPeerV4, ClientAndChannelV6> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static CHAN_TO_UDP_64: HashMap<ClientAndChannelV6, PortAndPeerV4> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static UDP_TO_CHAN_64: HashMap<PortAndPeerV6, ClientAndChannelV4> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);

#[inline(always)]
pub fn get_client_and_channel(key: impl Into<PortAndPeer>) -> Result<ClientAndChannel, Error> {
    let key = key.into();

    let maybe_v4 = get_client_and_channel_v4(key).map(ClientAndChannel::V4);
    let maybe_v6 = get_client_and_channel_v6(key).map(ClientAndChannel::V6);

    maybe_v4.or(maybe_v6)
}

#[inline(always)]
pub fn get_port_and_peer(key: impl Into<ClientAndChannel>) -> Result<PortAndPeer, Error> {
    let key = key.into();

    let maybe_v4 = get_port_and_peer_v4(key).map(PortAndPeer::V4);
    let maybe_v6 = get_port_and_peer_v6(key).map(PortAndPeer::V6);

    maybe_v4.or(maybe_v6)
}

#[inline(always)]
fn get_client_and_channel_v4(key: impl Into<PortAndPeer>) -> Result<ClientAndChannelV4, Error> {
    match key.into() {
        PortAndPeer::V4(pp) => unsafe { UDP_TO_CHAN_44.get(pp) }
            .copied()
            .ok_or(Error::NoEntry(SupportedChannel::Udp4ToChan)),
        PortAndPeer::V6(pp) => unsafe { UDP_TO_CHAN_64.get(pp) }
            .copied()
            .ok_or(Error::NoEntry(SupportedChannel::Udp6ToChan)),
    }
}

#[inline(always)]
fn get_client_and_channel_v6(key: impl Into<PortAndPeer>) -> Result<ClientAndChannelV6, Error> {
    match key.into() {
        PortAndPeer::V4(pp) => unsafe { UDP_TO_CHAN_46.get(pp) }
            .copied()
            .ok_or(Error::NoEntry(SupportedChannel::Udp4ToChan)),
        PortAndPeer::V6(pp) => unsafe { UDP_TO_CHAN_66.get(pp) }
            .copied()
            .ok_or(Error::NoEntry(SupportedChannel::Udp6ToChan)),
    }
}

#[inline(always)]
fn get_port_and_peer_v4(key: impl Into<ClientAndChannel>) -> Result<PortAndPeerV4, Error> {
    match key.into() {
        ClientAndChannel::V4(cc) => unsafe { CHAN_TO_UDP_44.get(cc) }
            .copied()
            .ok_or(Error::NoEntry(SupportedChannel::Chan4ToUdp)),
        ClientAndChannel::V6(cc) => unsafe { CHAN_TO_UDP_64.get(cc) }
            .copied()
            .ok_or(Error::NoEntry(SupportedChannel::Chan6ToUdp)),
    }
}

#[inline(always)]
fn get_port_and_peer_v6(key: impl Into<ClientAndChannel>) -> Result<PortAndPeerV6, Error> {
    match key.into() {
        ClientAndChannel::V4(cc) => unsafe { CHAN_TO_UDP_46.get(cc) }
            .copied()
            .ok_or(Error::NoEntry(SupportedChannel::Chan4ToUdp)),
        ClientAndChannel::V6(cc) => unsafe { CHAN_TO_UDP_66.get(cc) }
            .copied()
            .ok_or(Error::NoEntry(SupportedChannel::Chan6ToUdp)),
    }
}

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
