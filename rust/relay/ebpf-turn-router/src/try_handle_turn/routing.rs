//! Houses all combinations of IPv4 <> IPv6 and Channel <> UDP mappings.
//!
//! Testing has shown that these maps are safe to use as long as we aren't
//! writing to them from multiple threads at the same time. Since we only update these
//! from the single-threaded eventloop in userspace, we are ok.
//! See <https://github.com/firezone/firezone/issues/10138#issuecomment-3186074350>.

use aya_ebpf::{macros::map, maps::HashMap};
use ebpf_shared::{
    ClientAndChannel, ClientAndChannelV4, ClientAndChannelV6, PortAndPeer, PortAndPeerV4,
    PortAndPeerV6, RateLimiter, Route, Verdict,
};

use crate::{time::KernelInstant, try_handle_turn::Error};

use super::error::SupportedChannel;

const NUM_ENTRIES: u32 = 0x10000;

#[map]
static CHAN_TO_UDP_44: HashMap<ClientAndChannelV4, Route<PortAndPeerV4>> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static UDP_TO_CHAN_44: HashMap<PortAndPeerV4, Route<ClientAndChannelV4>> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static CHAN_TO_UDP_66: HashMap<ClientAndChannelV6, Route<PortAndPeerV6>> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static UDP_TO_CHAN_66: HashMap<PortAndPeerV6, Route<ClientAndChannelV6>> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static CHAN_TO_UDP_46: HashMap<ClientAndChannelV4, Route<PortAndPeerV6>> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static UDP_TO_CHAN_46: HashMap<PortAndPeerV4, Route<ClientAndChannelV6>> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static CHAN_TO_UDP_64: HashMap<ClientAndChannelV6, Route<PortAndPeerV4>> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);
#[map]
static UDP_TO_CHAN_64: HashMap<PortAndPeerV6, Route<ClientAndChannelV4>> =
    HashMap::with_max_entries(NUM_ENTRIES, 0);

/// Looks up where to send traffic from a peer and charges it against the channel's throughput limit.
#[inline(always)]
pub fn route_from_peer(
    key: impl Into<PortAndPeer>,
    num_bytes: u16,
) -> Result<(ClientAndChannel, Verdict), Error> {
    let key = key.into();

    if let Ok((cc, verdict)) = charge_client_and_channel_v4(key, num_bytes) {
        return Ok((ClientAndChannel::V4(cc), verdict));
    }

    let (cc, verdict) = charge_client_and_channel_v6(key, num_bytes)?;

    Ok((ClientAndChannel::V6(cc), verdict))
}

/// Looks up where to send traffic from a client and charges it against the channel's throughput limit.
#[inline(always)]
pub fn route_from_client(
    key: impl Into<ClientAndChannel>,
    num_bytes: u16,
) -> Result<(PortAndPeer, Verdict), Error> {
    let key = key.into();

    if let Ok((pp, verdict)) = charge_port_and_peer_v4(key, num_bytes) {
        return Ok((PortAndPeer::V4(pp), verdict));
    }

    let (pp, verdict) = charge_port_and_peer_v6(key, num_bytes)?;

    Ok((PortAndPeer::V6(pp), verdict))
}

#[inline(always)]
fn charge_client_and_channel_v4(
    key: PortAndPeer,
    num_bytes: u16,
) -> Result<(ClientAndChannelV4, Verdict), Error> {
    match key {
        PortAndPeer::V4(pp) => charge(&UDP_TO_CHAN_44, &pp, num_bytes)
            .ok_or(Error::NoEntry(SupportedChannel::Udp4ToChan)),
        PortAndPeer::V6(pp) => charge(&UDP_TO_CHAN_64, &pp, num_bytes)
            .ok_or(Error::NoEntry(SupportedChannel::Udp6ToChan)),
    }
}

#[inline(always)]
fn charge_client_and_channel_v6(
    key: PortAndPeer,
    num_bytes: u16,
) -> Result<(ClientAndChannelV6, Verdict), Error> {
    match key {
        PortAndPeer::V4(pp) => charge(&UDP_TO_CHAN_46, &pp, num_bytes)
            .ok_or(Error::NoEntry(SupportedChannel::Udp4ToChan)),
        PortAndPeer::V6(pp) => charge(&UDP_TO_CHAN_66, &pp, num_bytes)
            .ok_or(Error::NoEntry(SupportedChannel::Udp6ToChan)),
    }
}

#[inline(always)]
fn charge_port_and_peer_v4(
    key: ClientAndChannel,
    num_bytes: u16,
) -> Result<(PortAndPeerV4, Verdict), Error> {
    match key {
        ClientAndChannel::V4(cc) => charge(&CHAN_TO_UDP_44, &cc, num_bytes)
            .ok_or(Error::NoEntry(SupportedChannel::Chan4ToUdp)),
        ClientAndChannel::V6(cc) => charge(&CHAN_TO_UDP_64, &cc, num_bytes)
            .ok_or(Error::NoEntry(SupportedChannel::Chan6ToUdp)),
    }
}

#[inline(always)]
fn charge_port_and_peer_v6(
    key: ClientAndChannel,
    num_bytes: u16,
) -> Result<(PortAndPeerV6, Verdict), Error> {
    match key {
        ClientAndChannel::V4(cc) => charge(&CHAN_TO_UDP_46, &cc, num_bytes)
            .ok_or(Error::NoEntry(SupportedChannel::Chan4ToUdp)),
        ClientAndChannel::V6(cc) => charge(&CHAN_TO_UDP_66, &cc, num_bytes)
            .ok_or(Error::NoEntry(SupportedChannel::Chan6ToUdp)),
    }
}

/// Charges a packet against the rate limiter stored in the map entry.
#[inline(always)]
fn charge<K, V>(map: &HashMap<K, Route<V>>, key: &K, num_bytes: u16) -> Option<(V, Verdict)>
where
    V: Copy,
{
    let route = map.get_ptr_mut(key)?;

    // SAFETY: The pointer comes from a successful lookup and map values are never freed while the program runs.
    // Other CPUs may charge the same limiter concurrently, e.g. when relaying between two allocations on this Relay,
    // so we never create a reference to it.
    // The limiter's tolerances are orders of magnitude longer than a scheduler tick, so the coarse clock suffices.
    let (dst, verdict) = unsafe {
        let verdict = RateLimiter::check_shared(
            &raw mut (*route).limiter,
            || KernelInstant::now_coarse().as_nanos(),
            num_bytes,
        );

        ((*route).dst, verdict)
    };

    Some((dst, verdict))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Memory overhead of an eBPF map.
    ///
    /// Determined empirically.
    const HASH_MAP_OVERHEAD: f32 = 1.5;

    #[test]
    fn hashmaps_are_less_than_48_mb() {
        let entry_sizes = [
            entry_size::<ClientAndChannelV4, PortAndPeerV4>(),
            entry_size::<PortAndPeerV4, ClientAndChannelV4>(),
            entry_size::<ClientAndChannelV6, PortAndPeerV6>(),
            entry_size::<PortAndPeerV6, ClientAndChannelV6>(),
            entry_size::<ClientAndChannelV4, PortAndPeerV6>(),
            entry_size::<PortAndPeerV4, ClientAndChannelV6>(),
            entry_size::<ClientAndChannelV6, PortAndPeerV4>(),
            entry_size::<PortAndPeerV6, ClientAndChannelV4>(),
        ];

        let total_map_size =
            entry_sizes.iter().sum::<usize>() as f32 * NUM_ENTRIES as f32 * HASH_MAP_OVERHEAD;
        let total_map_size_mb = total_map_size / 1024_f32 / 1024_f32;

        assert!(
            total_map_size_mb < 48_f32,
            "Total map size = {total_map_size_mb} MB"
        );
    }

    fn entry_size<K, V>() -> usize {
        core::mem::size_of::<K>() + core::mem::size_of::<Route<V>>()
    }
}
