#![cfg_attr(target_arch = "bpf", no_std)]
#![cfg_attr(target_arch = "bpf", no_main)]

use crate::error::Error;
use aya_ebpf::{
    bindings::xdp_action,
    macros::{map, xdp},
    maps::HashMap,
    programs::XdpContext,
};
use aya_log_ebpf::*;
use channel_data::{CdHdr, ChannelData};
use ebpf_shared::{ClientAndChannelV4, ClientAndChannelV6, PortAndPeerV4, PortAndPeerV6};
use error::{SupportedChannel, UnsupportedChannel};
use eth::Eth;
use ip4::Ip4;
use ip6::Ip6;
use move_headers::{
    add_channel_data_header_ipv4, add_channel_data_header_ipv6, remove_channel_data_header_ipv4,
    remove_channel_data_header_ipv6,
};
use network_types::{
    eth::EtherType,
    ip::{IpProto, Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};
use udp::Udp;

mod channel_data;
mod checksum;
mod config;
mod error;
mod eth;
mod ip4;
mod ip6;
mod move_headers;
mod ref_mut_at;
mod stats;
mod udp;

const NUM_ENTRIES: u32 = 0x10000;

// TODO: Update flags to `BPF_F_NO_PREALLOC` to guarantee atomicity? Needs research.

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

#[xdp]
pub fn handle_turn(ctx: XdpContext) -> u32 {
    trace!(
        &ctx,
        "udp-checksumming = {}, allocation-range = {}..={}",
        if config::udp_checksum_enabled() {
            "true"
        } else {
            "false"
        },
        *config::allocation_range().start(),
        *config::allocation_range().end(),
    );

    try_handle_turn(&ctx).unwrap_or_else(|e| match e {
        Error::NotIp | Error::NotUdp => xdp_action::XDP_PASS,

        Error::PacketTooShort
        | Error::NotTurn
        | Error::NotAChannelDataMessage
        | Error::Ipv4PacketWithOptions
        | Error::NoMacAddress
        | Error::UnsupportedChannel(_)
        | Error::NoEntry(_) => {
            debug!(&ctx, "Passing packet to userspace: {}", e);

            xdp_action::XDP_PASS
        }

        Error::BadChannelDataLength
        | Error::XdpStoreBytesFailed(_)
        | Error::XdpAdjustHeadFailed(_)
        | Error::XdpLoadBytesFailed(_) => {
            warn!(&ctx, "Dropping packet: {}", e);

            xdp_action::XDP_DROP
        }
    })
}

#[inline(always)]
fn try_handle_turn(ctx: &XdpContext) -> Result<u32, Error> {
    // Safety: This is the only instance of `Eth`.
    let eth = unsafe { Eth::parse(ctx) }?;

    match eth.ether_type() {
        EtherType::Ipv4 => try_handle_turn_ipv4(ctx, eth)?,
        EtherType::Ipv6 => try_handle_turn_ipv6(ctx, eth)?,
        _ => return Err(Error::NotIp),
    };

    // If we get to here, we modified the packet and need to send it back out again.

    Ok(xdp_action::XDP_TX)
}

#[inline(always)]
fn try_handle_turn_ipv4(ctx: &XdpContext, eth: Eth) -> Result<(), Error> {
    // Safety: This is the only instance of `Ip4`.
    let ipv4 = unsafe { Ip4::parse(ctx) }?;

    eth::save_mac_for_ipv4(ipv4.src(), eth.src());
    eth::save_mac_for_ipv4(ipv4.dst(), eth.dst());

    if ipv4.protocol() != IpProto::Udp {
        return Err(Error::NotUdp);
    }

    // Safety: This is the only instance of `Udp` in this scope.
    let udp = unsafe { Udp::parse(ctx, Ipv4Hdr::LEN) }?; // TODO: Change the API so we parse the UDP header _from_ the ipv4 struct?
    let udp_payload_len = udp.payload_len();

    trace!(
        ctx,
        "New packet from {:i}:{} for {:i}:{} with UDP payload {}",
        ipv4.src(),
        udp.src(),
        ipv4.dst(),
        udp.dst(),
        udp_payload_len
    );

    if config::allocation_range().contains(&udp.dst()) {
        try_handle_ipv4_udp_to_channel_data(ctx, eth, ipv4, udp)?;
        stats::emit_data_relayed(ctx, udp_payload_len);

        return Ok(());
    }

    if udp.dst() == 3478 {
        try_handle_ipv4_channel_data_to_udp(ctx, eth, ipv4, udp)?;
        stats::emit_data_relayed(ctx, udp_payload_len - CdHdr::LEN as u16);

        return Ok(());
    }

    Err(Error::NotTurn)
}

#[inline(always)]
fn try_handle_ipv4_channel_data_to_udp(
    ctx: &XdpContext,
    eth: Eth,
    ipv4: Ip4,
    udp: Udp,
) -> Result<(), Error> {
    // Safety: This is the only instance of `Udp` in this scope.
    let cd = unsafe { ChannelData::parse(ctx, Ipv4Hdr::LEN) }?;

    let key = ClientAndChannelV4::new(ipv4.src(), udp.src(), cd.number());

    // SAFETY: ???
    let port_and_peer = unsafe { CHAN_TO_UDP_44.get(&key) }.ok_or_else(|| {
        if unsafe { CHAN_TO_UDP_46.get(&key) }.is_some() {
            return Error::UnsupportedChannel(UnsupportedChannel::ChanToUdp46);
        }

        Error::NoEntry(SupportedChannel::ChanToUdp44)
    })?;

    let new_src = ipv4.dst(); // The IP we received the packet on will be the new source IP.
    let new_dst = port_and_peer.peer_ip();
    let new_ipv4_total_len = ipv4.total_len() - CdHdr::LEN as u16;

    eth.update(new_dst)?;

    let pseudo_header = ipv4.update(new_src, new_dst, new_ipv4_total_len);

    let new_udp_len = udp.len() - CdHdr::LEN as u16;
    udp.update(
        pseudo_header,
        port_and_peer.allocation_port(),
        port_and_peer.peer_port(),
        new_udp_len,
        cd.number(),
        cd.length(),
    );

    remove_channel_data_header_ipv4(ctx)?;

    Ok(())
}

#[inline(always)]
fn try_handle_ipv4_udp_to_channel_data(
    ctx: &XdpContext,
    eth: Eth,
    ipv4: Ip4,
    udp: Udp,
) -> Result<(), Error> {
    let key = PortAndPeerV4::new(ipv4.src(), udp.dst(), udp.src());

    let client_and_channel = unsafe { UDP_TO_CHAN_44.get(&key) }.ok_or_else(|| {
        if unsafe { UDP_TO_CHAN_46.get(&key) }.is_some() {
            return Error::UnsupportedChannel(UnsupportedChannel::UdpToChan46);
        }

        Error::NoEntry(SupportedChannel::UdpToChan44)
    })?;

    let new_src = ipv4.dst(); // The IP we received the packet on will be the new source IP.
    let new_dst = client_and_channel.client_ip();
    let new_ipv4_total_len = ipv4.total_len() + CdHdr::LEN as u16;

    eth.update(new_dst)?;

    let pseudo_header = ipv4.update(new_src, new_dst, new_ipv4_total_len);

    let udp_len = udp.len();
    let new_udp_len = udp_len + CdHdr::LEN as u16;

    let channel_number = client_and_channel.channel();
    let channel_data_length = udp_len - UdpHdr::LEN as u16; // The `length` field in the UDP header includes the header itself. For the channel-data field, we only want the length of the payload.

    udp.update(
        pseudo_header,
        3478,
        client_and_channel.client_port(),
        new_udp_len,
        channel_number,
        channel_data_length,
    );

    add_channel_data_header_ipv4(
        ctx,
        CdHdr {
            number: channel_number.to_be_bytes(),
            length: channel_data_length.to_be_bytes(),
        },
    )?;

    Ok(())
}

#[inline(always)]
fn try_handle_turn_ipv6(ctx: &XdpContext, eth: Eth) -> Result<(), Error> {
    // Safety: This is the only instance of `Ip6` in this scope.
    let ipv6 = unsafe { Ip6::parse(ctx) }?;

    eth::save_mac_for_ipv6(ipv6.src(), eth.src());
    eth::save_mac_for_ipv6(ipv6.dst(), eth.dst());

    if ipv6.protocol() != IpProto::Udp {
        return Err(Error::NotUdp);
    }

    // Safety: This is the only instance of `Udp` in this scope.
    let udp = unsafe { Udp::parse(ctx, Ipv6Hdr::LEN) }?; // TODO: Change the API so we parse the UDP header _from_ the ipv6 struct?
    let udp_payload_len = udp.payload_len();

    trace!(
        ctx,
        "New packet from {:i}:{} for {:i}:{} with UDP payload {}",
        ipv6.src(),
        udp.src(),
        ipv6.dst(),
        udp.dst(),
        udp_payload_len
    );

    if config::allocation_range().contains(&udp.dst()) {
        try_handle_ipv6_udp_to_channel_data(ctx, eth, ipv6, udp)?;
        stats::emit_data_relayed(ctx, udp_payload_len);

        return Ok(());
    }

    if udp.dst() == 3478 {
        try_handle_ipv6_channel_data_to_udp(ctx, eth, ipv6, udp)?;
        stats::emit_data_relayed(ctx, udp_payload_len - CdHdr::LEN as u16);

        return Ok(());
    }

    Err(Error::NotTurn)
}

fn try_handle_ipv6_udp_to_channel_data(
    ctx: &XdpContext,
    eth: Eth,
    ipv6: Ip6,
    udp: Udp,
) -> Result<(), Error> {
    let key = PortAndPeerV6::new(ipv6.src(), udp.dst(), udp.src());

    let client_and_channel = unsafe { UDP_TO_CHAN_66.get(&key) }.ok_or_else(|| {
        if unsafe { UDP_TO_CHAN_64.get(&key) }.is_some() {
            return Error::UnsupportedChannel(UnsupportedChannel::UdpToChan64);
        }

        Error::NoEntry(SupportedChannel::UdpToChan66)
    })?;

    let new_src = ipv6.dst(); // The IP we received the packet on will be the new source IP.
    let new_dst = client_and_channel.client_ip();
    let new_ipv6_total_len = ipv6.payload_len() + CdHdr::LEN as u16;

    eth.update(new_dst)?;

    let pseudo_header = ipv6.update(new_src, new_dst, new_ipv6_total_len);

    let udp_len = udp.len();
    let new_udp_len = udp_len + CdHdr::LEN as u16;

    let channel_number = client_and_channel.channel();
    let channel_data_length = udp_len - UdpHdr::LEN as u16; // The `length` field in the UDP header includes the header itself. For the channel-data field, we only want the length of the payload.

    udp.update(
        pseudo_header,
        3478,
        client_and_channel.client_port(),
        new_udp_len,
        channel_number,
        channel_data_length,
    );

    add_channel_data_header_ipv6(
        ctx,
        CdHdr {
            number: channel_number.to_be_bytes(),
            length: channel_data_length.to_be_bytes(),
        },
    )?;

    Ok(())
}

fn try_handle_ipv6_channel_data_to_udp(
    ctx: &XdpContext,
    eth: Eth,
    ipv6: Ip6,
    udp: Udp,
) -> Result<(), Error> {
    // Safety: This is the only instance of `ChannelData` in this scope.
    let cd = unsafe { ChannelData::parse(ctx, Ipv6Hdr::LEN) }?;

    let key = ClientAndChannelV6::new(ipv6.src(), udp.src(), cd.number());

    // SAFETY: ???
    let port_and_peer = unsafe { CHAN_TO_UDP_66.get(&key) }.ok_or_else(|| {
        if unsafe { CHAN_TO_UDP_64.get(&key) }.is_some() {
            return Error::UnsupportedChannel(UnsupportedChannel::ChanToUdp64);
        }

        Error::NoEntry(SupportedChannel::ChanToUdp66)
    })?;

    let new_src = ipv6.dst(); // The IP we received the packet on will be the new source IP.
    let new_dst = port_and_peer.peer_ip();
    let new_ipv6_payload_len = ipv6.payload_len() - CdHdr::LEN as u16;

    eth.update(new_dst)?;

    let pseudo_header = ipv6.update(new_src, new_dst, new_ipv6_payload_len);

    let new_udp_len = udp.len() - CdHdr::LEN as u16;
    udp.update(
        pseudo_header,
        port_and_peer.allocation_port(),
        port_and_peer.peer_port(),
        new_udp_len,
        cd.number(),
        cd.length(),
    );

    remove_channel_data_header_ipv6(ctx)?;

    Ok(())
}

/// Defines our panic handler.
///
/// This doesn't do anything because we can never actually panic in eBPF.
/// Attempting to link a program that wants to abort fails at compile time anyway.
#[cfg(target_arch = "bpf")]
#[panic_handler]
fn on_panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[cfg(not(target_arch = "bpf"))]
fn main() {
    panic!("This program is meant to be compiled as an eBPF program.");
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
