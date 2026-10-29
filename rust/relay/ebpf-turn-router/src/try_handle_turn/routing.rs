//! Houses all combinations of IPv4 <> IPv6 and Channel <> UDP mappings.
//!
//! Testing has shown that these maps are safe to use as long as we aren't
//! writing to them from multiple threads at the same time. Since we only update these
//! from the single-threaded eventloop in userspace, we are ok.
//! See <https://github.com/firezone/firezone/issues/10138#issuecomment-3186074350>.

use aya_ebpf::{macros::map, maps::HashMap};
use ebpf_shared::{
    ClientAndChannel, ClientAndChannelV4, ClientAndChannelV6, PortAndPeer, PortAndPeerV4,
    PortAndPeerV6, Route, Verdict,
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

/// Looks up where to send traffic from a peer without charging it.
///
/// Used when relaying between two allocations on this relay: the traffic has already been charged
/// to the channel it arrived on.
#[inline(always)]
pub fn get_client_and_channel(key: impl Into<PortAndPeer>) -> Result<ClientAndChannel, Error> {
    let key = key.into();

    let maybe_v4 = get_client_and_channel_v4(key).map(ClientAndChannel::V4);
    let maybe_v6 = get_client_and_channel_v6(key).map(ClientAndChannel::V6);

    maybe_v4.or(maybe_v6)
}

#[inline(always)]
fn get_client_and_channel_v4(key: impl Into<PortAndPeer>) -> Result<ClientAndChannelV4, Error> {
    match key.into() {
        PortAndPeer::V4(pp) => unsafe { UDP_TO_CHAN_44.get(&pp) }
            .map(|route| route.dst)
            .ok_or(Error::NoEntry(SupportedChannel::Udp4ToChan)),
        PortAndPeer::V6(pp) => unsafe { UDP_TO_CHAN_64.get(&pp) }
            .map(|route| route.dst)
            .ok_or(Error::NoEntry(SupportedChannel::Udp6ToChan)),
    }
}

#[inline(always)]
fn get_client_and_channel_v6(key: impl Into<PortAndPeer>) -> Result<ClientAndChannelV6, Error> {
    match key.into() {
        PortAndPeer::V4(pp) => unsafe { UDP_TO_CHAN_46.get(&pp) }
            .map(|route| route.dst)
            .ok_or(Error::NoEntry(SupportedChannel::Udp4ToChan)),
        PortAndPeer::V6(pp) => unsafe { UDP_TO_CHAN_66.get(&pp) }
            .map(|route| route.dst)
            .ok_or(Error::NoEntry(SupportedChannel::Udp6ToChan)),
    }
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
///
/// The limiter is updated in place without synchronisation.
/// RSS steers all packets of a channel to the same CPU, so concurrent updates of the same
/// entry are rare; a lost update merely lets a packet through for free.
#[inline(always)]
fn charge<K, V>(map: &HashMap<K, Route<V>>, key: &K, num_bytes: u16) -> Option<(V, Verdict)>
where
    V: Copy,
{
    let route = map.get_ptr_mut(key)?;
    // SAFETY: The pointer comes from a successful lookup and map values are never freed while the program runs.
    let route = unsafe { &mut *route };

    // Reading the clock is comparatively expensive, so only do it for channels that are limited.
    let verdict = if route.limiter.is_unlimited() {
        Verdict::Pass
    } else {
        route
            .limiter
            .check(KernelInstant::now().as_nanos(), num_bytes)
    };

    Some((route.dst, verdict))
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
