#![cfg_attr(target_arch = "bpf", no_std)]
#![cfg_attr(target_arch = "bpf", no_main)]

use crate::error::Error;
use aya_ebpf::{
    bindings::xdp_action,
    helpers::bpf_xdp_adjust_head,
    macros::{map, xdp},
    maps::{HashMap, PerCpuArray},
    programs::XdpContext,
};
use aya_log_ebpf::*;
use channel_data::CdHdr;
use checksum::ChecksumUpdate;
use ebpf_shared::{
    ClientAndChannelV4, ClientAndChannelV6, InterfaceAddressV4, InterfaceAddressV6, PortAndPeerV4,
    PortAndPeerV6,
};
use error::SupportedChannel;
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{IpProto, Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};
use ref_mut_at::{ref_at, ref_mut_at};

mod channel_data;
mod checksum;
mod config;
mod error;
mod ref_mut_at;
mod stats;

const NUM_ENTRIES: u32 = 0x10000;
const LOWER_PORT: u16 = 49152; // Lower bound for TURN UDP ports
const UPPER_PORT: u16 = 65535; // Upper bound for TURN UDP ports
const CHAN_START: u16 = 0x4000; // Channel number start
const CHAN_END: u16 = 0x7FFF; // Channel number end

// SAFETY: Testing has shown that these maps are safe to use as long as we aren't
// writing to them from multiple threads at the same time. Since we only update these
// from the single-threaded eventloop in userspace, we are ok.
// See https://github.com/firezone/firezone/issues/10138#issuecomment-3186074350

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

// Per-CPU data structures to learn relay interface addresses
#[map]
static INT_ADDR_V4: PerCpuArray<InterfaceAddressV4> = PerCpuArray::with_max_entries(1, 0);
#[map]
static INT_ADDR_V6: PerCpuArray<InterfaceAddressV6> = PerCpuArray::with_max_entries(1, 0);

#[xdp]
pub fn handle_turn(ctx: XdpContext) -> u32 {
    try_handle_turn(&ctx).unwrap_or_else(|e| match e {
        Error::NotIp | Error::NotUdp => xdp_action::XDP_PASS,

        Error::InterfaceIpv4AddressAccessFailed
        | Error::InterfaceIpv4AddressNotLearned
        | Error::InterfaceIpv6AddressAccessFailed
        | Error::InterfaceIpv6AddressNotLearned
        | Error::PacketTooShort
        | Error::NotTurn
        | Error::NoEntry(_)
        | Error::NotAChannelDataMessage
        | Error::Ipv4ChecksumMissing
        | Error::Ipv4PacketWithOptions => {
            debug!(&ctx, "Passing packet to the stack: {}", e);

            xdp_action::XDP_PASS
        }

        Error::BadChannelDataLength | Error::XdpAdjustHeadFailed(_) => {
            warn!(&ctx, "Dropping packet: {}", e);

            xdp_action::XDP_DROP
        }
    })
}

#[inline(always)]
fn try_handle_turn(ctx: &XdpContext) -> Result<u32, Error> {
    // SAFETY: Offset points to the start of the Ethernet header.
    let eth = unsafe { ref_at::<EthHdr>(ctx, 0)? };

    match eth.ether_type {
        EtherType::Ipv4 => try_handle_turn_ipv4(ctx)?,
        EtherType::Ipv6 => try_handle_turn_ipv6(ctx)?,
        _ => return Err(Error::NotIp),
    };

    // If we get to here, we modified the packet and need to send it back out again.
    Ok(xdp_action::XDP_TX)
}

#[inline(always)]
fn try_handle_turn_ipv4(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: Offset points to the start of the IPv4 header.
    let ipv4 = unsafe { ref_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };

    learn_interface_ipv4_address(ipv4)?;

    if ipv4.proto != IpProto::Udp {
        return Err(Error::NotUdp);
    }

    if ipv4.ihl() != 5 {
        // IPv4 with options is not supported
        return Err(Error::Ipv4PacketWithOptions);
    }

    // SAFETY: Offset points to the start of the UDP header.
    let udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };
    let udp_payload_len = udp.len() - UdpHdr::LEN as u16;

    trace!(
        ctx,
        "New packet from {:i}:{} for {:i}:{} with UDP payload {}",
        ipv4.src_addr(),
        udp.source(),
        ipv4.dst_addr(),
        udp.dest(),
        udp_payload_len
    );

    if (LOWER_PORT..=UPPER_PORT).contains(&udp.dest()) {
        try_handle_ipv4_udp_to_channel_data(ctx)?;
        stats::emit_data_relayed(ctx, udp_payload_len);

        return Ok(());
    }

    if udp.dest() == 3478 {
        try_handle_ipv4_channel_data_to_udp(ctx)?;
        stats::emit_data_relayed(ctx, udp_payload_len - CdHdr::LEN as u16);

        return Ok(());
    }

    Err(Error::NotTurn)
}

#[inline(always)]
fn try_handle_turn_ipv6(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: Offset points to the start of the IPv6 header.
    let ipv6 = unsafe { ref_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };

    learn_interface_ipv6_address(ipv6)?;

    if ipv6.next_hdr != IpProto::Udp {
        return Err(Error::NotUdp);
    }

    // SAFETY: Offset points to the start of the UDP header.
    let udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    let udp_payload_len = udp.len() - UdpHdr::LEN as u16;

    trace!(
        ctx,
        "New packet from {:i}:{} for {:i}:{} with UDP payload {}",
        ipv6.src_addr(),
        udp.source(),
        ipv6.dst_addr(),
        udp.dest(),
        udp_payload_len
    );

    if (LOWER_PORT..=UPPER_PORT).contains(&udp.dest()) {
        try_handle_ipv6_udp_to_channel_data(ctx)?;
        stats::emit_data_relayed(ctx, udp_payload_len);

        return Ok(());
    }

    if udp.dest() == 3478 {
        try_handle_ipv6_channel_data_to_udp(ctx)?;
        stats::emit_data_relayed(ctx, udp_payload_len - CdHdr::LEN as u16);

        return Ok(());
    }

    Err(Error::NotTurn)
}

#[inline(always)]
fn learn_interface_ipv4_address(ipv4: &Ipv4Hdr) -> Result<(), Error> {
    let interface_addr = INT_ADDR_V4
        .get_ptr_mut(0)
        .ok_or(Error::InterfaceIpv4AddressAccessFailed)?;

    let dst_ip = ipv4.dst_addr();

    // SAFETY: These are per-cpu maps so we don't need to worry about thread safety.
    unsafe {
        if (*interface_addr).get().is_none() {
            (*interface_addr).set(dst_ip);
        }
    }

    Ok(())
}

#[inline(always)]
fn learn_interface_ipv6_address(ipv6: &Ipv6Hdr) -> Result<(), Error> {
    let interface_addr = INT_ADDR_V6
        .get_ptr_mut(0)
        .ok_or(Error::InterfaceIpv6AddressAccessFailed)?;

    let dst_ip = ipv6.dst_addr();

    // SAFETY: These are per-cpu maps so we don't need to worry about thread safety.
    unsafe {
        if (*interface_addr).get().is_none() {
            (*interface_addr).set(dst_ip);
        }
    }

    Ok(())
}

#[inline(always)]
fn try_handle_ipv4_udp_to_channel_data(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: Offset points to the start of the IPv4 header.
    let ipv4 = unsafe { ref_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: Offset points to the start of the UDP header.
    let udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };

    let key = PortAndPeerV4::new(ipv4.src_addr(), udp.dest(), udp.source());

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(client_and_channel) = unsafe { UDP_TO_CHAN_44.get(&key) } {
        handle_ipv4_udp_to_ipv4_channel(ctx, client_and_channel)?;
        return Ok(());
    }

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(client_and_channel) = unsafe { UDP_TO_CHAN_46.get(&key) } {
        handle_ipv4_udp_to_ipv6_channel(ctx, client_and_channel)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Udp4ToChan))
}

#[inline(always)]
fn try_handle_ipv4_channel_data_to_udp(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: Offset points to the start of the Ethernet header.
    let ipv4 = unsafe { ref_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: Offset points to the start of the UDP header.
    let udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };

    // SAFETY: Offset points to the start of the channel data header.
    let cd = unsafe { ref_at::<CdHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN)? };

    let channel_number = u16::from_be_bytes(cd.number);

    if !(CHAN_START..=CHAN_END).contains(&channel_number) {
        return Err(Error::NotAChannelDataMessage);
    }

    let channel_data_len = u16::from_be_bytes(cd.length);
    let expected_channel_data_len = udp.len() - UdpHdr::LEN as u16 - CdHdr::LEN as u16;

    // This can happen if we receive packets formed via GSO, like on a loopback interface.
    if channel_data_len != expected_channel_data_len {
        return Err(Error::BadChannelDataLength);
    }

    let key = ClientAndChannelV4::new(ipv4.src_addr(), udp.source(), channel_number);

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(port_and_peer) = unsafe { CHAN_TO_UDP_44.get(&key) } {
        // IPv4 to IPv4 - existing logic
        handle_ipv4_channel_to_ipv4_udp(ctx, port_and_peer)?;
        return Ok(());
    }

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(port_and_peer) = unsafe { CHAN_TO_UDP_46.get(&key) } {
        handle_ipv4_channel_to_ipv6_udp(ctx, port_and_peer)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Chan4ToUdp))
}

#[inline(always)]
fn try_handle_ipv6_udp_to_channel_data(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: Offset points to the start of the IPv6 header.
    let ipv6 = unsafe { ref_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: Offset points to the start of the UDP header.
    let udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };

    let key = PortAndPeerV6::new(ipv6.src_addr(), udp.dest(), udp.source());

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(client_and_channel) = unsafe { UDP_TO_CHAN_66.get(&key) } {
        handle_ipv6_udp_to_ipv6_channel(ctx, client_and_channel)?;
        return Ok(());
    }

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(client_and_channel) = unsafe { UDP_TO_CHAN_64.get(&key) } {
        handle_ipv6_udp_to_ipv4_channel(ctx, client_and_channel)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Udp6ToChan))
}

#[inline(always)]
fn try_handle_ipv6_channel_data_to_udp(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: Offset points to the start of the IPv6 header.
    let ipv6 = unsafe { ref_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: Offset points to the start of the UDP header.
    let udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };

    // SAFETY: Offset points to the start of the channel data header.
    let cd = unsafe { ref_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };

    let channel_number = u16::from_be_bytes(cd.number);

    if !(CHAN_START..=CHAN_END).contains(&channel_number) {
        return Err(Error::NotAChannelDataMessage);
    }

    let channel_data_len = u16::from_be_bytes(cd.length);
    let expected_channel_data_len = udp.len() - UdpHdr::LEN as u16 - CdHdr::LEN as u16;

    // This can happen if we receive packets formed via GSO, like on a loopback interface.
    if channel_data_len != expected_channel_data_len {
        return Err(Error::BadChannelDataLength);
    }

    let key = ClientAndChannelV6::new(ipv6.src_addr(), udp.source(), u16::from_be_bytes(cd.number));

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(port_and_peer) = unsafe { CHAN_TO_UDP_66.get(&key) } {
        handle_ipv6_channel_to_ipv6_udp(ctx, port_and_peer)?;
        return Ok(());
    }

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(port_and_peer) = unsafe { CHAN_TO_UDP_64.get(&key) } {
        handle_ipv6_channel_to_ipv4_udp(ctx, port_and_peer)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Chan6ToUdp))
}

#[inline(always)]
fn handle_ipv4_udp_to_ipv4_channel(
    ctx: &XdpContext,
    client_and_channel: &ClientAndChannelV4,
) -> Result<(), Error> {
    const NET_EXPANSION: i32 = -(CdHdr::LEN as i32);

    adjust_head(ctx, NET_EXPANSION)?;

    // Now read the old packet data from its NEW location (shifted by 4 bytes)
    let old_data_offset = -NET_EXPANSION as usize;

    // SAFETY: Offset points to the start of the Ethernet header.
    let old_eth = unsafe { ref_at::<EthHdr>(ctx, old_data_offset)? };
    let old_eth_src = old_eth.src_addr;
    let old_eth_dst = old_eth.dst_addr;
    let old_eth_type = old_eth.ether_type;

    // SAFETY: Offset points to the start of the IPv4 header.
    let old_ipv4 = unsafe { ref_at::<Ipv4Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
    let old_ipv4_src = old_ipv4.src_addr();
    let old_ipv4_dst = old_ipv4.dst_addr();
    let old_ipv4_len = old_ipv4.total_len();
    let old_ipv4_check = old_ipv4.checksum();
    let old_ipv4_tos = old_ipv4.tos;
    let old_ipv4_id = old_ipv4.id();
    let old_ipv4_frag_off = old_ipv4.frag_off;
    let old_ipv4_ttl = old_ipv4.ttl;
    let old_ipv4_proto = old_ipv4.proto;

    // SAFETY: Offset points to the start of the UDP header.
    let old_udp = unsafe { ref_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN)? };
    let old_udp_len = old_udp.len();
    let old_udp_src = old_udp.source();
    let old_udp_dst = old_udp.dest();
    let old_udp_check = old_udp.check();

    //
    // 1. Ethernet header
    //

    // SAFETY: This is the only mutable instance of `EthHdr` in this scope.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
    eth.src_addr = old_eth_dst;
    eth.dst_addr = old_eth_src;
    eth.ether_type = old_eth_type;

    //
    // 2. IPv4 header
    //

    let new_ipv4_src = old_ipv4_dst;
    let new_ipv4_dst = client_and_channel.client_ip();
    let new_ipv4_len = old_ipv4_len + CdHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `Ipv4Hdr` in this scope.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };
    ipv4.set_version(4); // IPv4
    ipv4.set_ihl(5); // No options, 5 * 4 = 20 bytes
    ipv4.tos = old_ipv4_tos; // Preserve TOS/DSCP
    ipv4.set_total_len(new_ipv4_len);
    ipv4.set_id(old_ipv4_id); // Preserve fragment ID
    ipv4.frag_off = old_ipv4_frag_off; // Preserve fragment flags
    ipv4.ttl = old_ipv4_ttl; // Preserve TTL exactly
    ipv4.proto = old_ipv4_proto; // Protocol is UDP
    ipv4.set_src_addr(new_ipv4_src); // Swap source and destination
    ipv4.set_dst_addr(new_ipv4_dst); // Destination is the client IP
    ipv4.set_checksum(
        ChecksumUpdate::new(old_ipv4_check)
            .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
            .remove_u16(old_ipv4_len)
            .add_u32(u32::from_be_bytes(new_ipv4_dst.octets()))
            .add_u16(new_ipv4_len)
            .into_checksum(),
    );

    //
    // 3. UDP header
    //

    let new_udp_src = 3478_u16;
    let new_udp_dst = client_and_channel.client_port();
    let new_udp_len = old_udp_len + CdHdr::LEN as u16;
    let channel_number = client_and_channel.channel();
    let channel_data_length = old_udp_len - UdpHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `UdpHdr` in this scope.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    // TODO: Remove conditional checksums once we can test this fully in CI
    if old_udp_check == 0 || !crate::config::udp_checksum_enabled() {
        // No checksum is valid for UDP IPv4 - we didn't write it, but maybe a middlebox did
        udp.set_check(0);
    } else {
        let check = ChecksumUpdate::new(old_udp_check)
            .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
            .remove_u16(old_udp_src)
            .remove_u16(old_udp_dst)
            .remove_u16(old_udp_len)
            .remove_u16(old_udp_len)
            .add_u32(u32::from_be_bytes(new_ipv4_dst.octets()))
            .add_u16(new_udp_src)
            .add_u16(new_udp_dst)
            .add_u16(new_udp_len)
            .add_u16(new_udp_len)
            .add_u16(channel_number)
            .add_u16(channel_data_length)
            .into_checksum();

        if check == 0 {
            udp.set_check(0xFFFF); // Special case for zero checksum - write 0xFFFF to the wire
        } else {
            udp.set_check(check);
        }
    }

    //
    // 4. Channel data header
    //
    // SAFETY: This is the only mutable instance of `CdHdr` in this scope.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN)? };
    cd.number = channel_number.to_be_bytes();
    cd.length = channel_data_length.to_be_bytes();

    Ok(())
}

// Convert IPv4 to IPv6 and add channel data
#[inline(always)]
fn handle_ipv4_udp_to_ipv6_channel(
    ctx: &XdpContext,
    client_and_channel: &ClientAndChannelV6,
) -> Result<(), Error> {
    // Expand the packet by 24 bytes for IPv6 header and channel data header
    const NET_EXPANSION: i32 = -(Ipv6Hdr::LEN as i32 - Ipv4Hdr::LEN as i32 + CdHdr::LEN as i32);

    adjust_head(ctx, NET_EXPANSION)?;

    // Now read the old packet data from its NEW location (shifted by 24 bytes)
    let old_data_offset = -NET_EXPANSION as usize;

    // SAFETY: Offset points to the start of the Ethernet header.
    let old_eth = unsafe { ref_at::<EthHdr>(ctx, old_data_offset)? };
    let old_eth_src = old_eth.src_addr;
    let old_eth_dst = old_eth.dst_addr;

    // SAFETY: Offset points to the start of the IPv4 header.
    let old_ipv4 = unsafe { ref_at::<Ipv4Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
    let old_ipv4_src = old_ipv4.src_addr();
    let old_ipv4_dst = old_ipv4.dst_addr();
    let old_ipv4_len = old_ipv4.total_len();
    let old_ipv4_tos = old_ipv4.tos;
    let old_ipv4_ttl = old_ipv4.ttl;
    let old_ipv4_proto = old_ipv4.proto;

    // SAFETY: Offset points to the start of the UDP header.
    let old_udp = unsafe { ref_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN)? };
    let old_udp_src = old_udp.source();
    let old_udp_dst = old_udp.dest();
    let old_udp_len = old_udp.len();
    let old_udp_check = old_udp.check();

    //
    // 1. Ethernet header
    //

    // SAFETY: XDP context provides valid packet memory. Bounds checked by ref_mut_at.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
    eth.dst_addr = old_eth_src; // Swap source and destination
    eth.src_addr = old_eth_dst;
    eth.ether_type = EtherType::Ipv6; // Change to IPv6

    //
    // 2. IPv4 -> IPv6 header
    //

    // Get the learned IPv6 address
    let interface_addr = INT_ADDR_V6
        .get_ptr(0)
        .ok_or(Error::InterfaceIpv6AddressAccessFailed)?;

    // SAFETY: INT_ADDR_V6 is a PerCpuArray, so we can safely access it.
    let new_ipv6_src = unsafe {
        (*interface_addr)
            .get()
            .ok_or(Error::InterfaceIpv6AddressNotLearned)?
    };

    let new_ipv6_dst = client_and_channel.client_ip();
    let new_ipv6_len = old_ipv4_len - Ipv4Hdr::LEN as u16 + CdHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `Ipv6Hdr` in this scope.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    ipv6.set_version(6);
    ipv6.set_priority(old_ipv4_tos);
    ipv6.flow_label = [0, 0, 0]; // Default flow label
    ipv6.set_payload_len(new_ipv6_len);
    ipv6.next_hdr = old_ipv4_proto;
    ipv6.hop_limit = old_ipv4_ttl;
    ipv6.set_src_addr(new_ipv6_src);
    ipv6.set_dst_addr(new_ipv6_dst);

    //
    // 3. UDP header
    //

    let new_udp_src = 3478_u16;
    let new_udp_dst = client_and_channel.client_port();
    let new_udp_len = old_udp_len + CdHdr::LEN as u16;

    let channel_number = client_and_channel.channel();
    let channel_data_length = old_udp_len - UdpHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `UdpHdr` in this scope.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    // TODO: Remove conditional checksums once we can test this fully in CI
    if !crate::config::udp_checksum_enabled() {
        udp.set_check(0);
    } else {
        let check = ChecksumUpdate::new(old_udp_check)
            .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
            .remove_u32(u32::from_be_bytes(old_ipv4_dst.octets()))
            .remove_u16(old_udp_src)
            .remove_u16(old_udp_dst)
            .remove_u16(old_udp_len)
            .remove_u16(old_udp_len)
            .add_u128(u128::from_be_bytes(new_ipv6_src.octets()))
            .add_u128(u128::from_be_bytes(new_ipv6_dst.octets()))
            .add_u16(new_udp_src)
            .add_u16(new_udp_dst)
            .add_u16(new_udp_len)
            .add_u16(new_udp_len)
            .add_u16(channel_number)
            .add_u16(channel_data_length)
            .into_checksum();

        if check == 0 {
            udp.set_check(0xFFFF); // Special case for zero checksum - write 0xFFFF to the wire
        } else {
            udp.set_check(check);
        }
    }

    //
    // 4. Channel data header
    //

    // SAFETY: This is the only mutable instance of `CdHdr` in this scope.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };
    cd.number = channel_number.to_be_bytes();
    cd.length = channel_data_length.to_be_bytes();

    Ok(())
}

#[inline(always)]
fn handle_ipv4_channel_to_ipv4_udp(
    ctx: &XdpContext,
    port_and_peer: &PortAndPeerV4,
) -> Result<(), Error> {
    const NET_SHRINK: i32 = CdHdr::LEN as i32; // Shrink by 4 bytes for channel data header

    // SAFETY: Offset points to the start of the Ethernet header.
    let old_eth = unsafe { ref_at::<EthHdr>(ctx, 0)? };
    let old_eth_src = old_eth.src_addr;
    let old_eth_dst = old_eth.dst_addr;
    let old_eth_type = old_eth.ether_type;

    // SAFETY: Offset points to the start of the IPv4 header.
    let old_ipv4 = unsafe { ref_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };
    let old_ipv4_src = old_ipv4.src_addr();
    let old_ipv4_dst = old_ipv4.dst_addr();
    let old_ipv4_len = old_ipv4.total_len();
    let old_ipv4_check = old_ipv4.checksum();
    let old_ipv4_tos = old_ipv4.tos;
    let old_ipv4_id = old_ipv4.id();
    let old_ipv4_frag_off = old_ipv4.frag_off;
    let old_ipv4_ttl = old_ipv4.ttl;
    let old_ipv4_proto = old_ipv4.proto;

    // SAFETY: Offset points to the start of the UDP header.
    let old_udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };
    let old_udp_src = old_udp.source();
    let old_udp_dst = old_udp.dest();
    let old_udp_len = old_udp.len();
    let old_udp_check = old_udp.check();

    // Refuse to compute full UDP checksum.
    // We forged these packets, so something's wrong if this is zero.
    if old_udp_check == 0 {
        return Err(Error::Ipv4ChecksumMissing);
    }

    // SAFETY: Offset points to the start of the channel data header.
    let old_cd = unsafe { ref_at::<CdHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN)? };
    let channel_number = u16::from_be_bytes(old_cd.number);
    let channel_data_length = u16::from_be_bytes(old_cd.length);

    //
    // 1. Ethernet header
    //

    // SAFETY: This is the only mutable instance of `EthHdr` in this scope.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, NET_SHRINK as usize)? };
    eth.dst_addr = old_eth_src; // Swap source and destination
    eth.src_addr = old_eth_dst;
    eth.ether_type = old_eth_type;

    //
    // 2. IPv4 header
    //

    let new_ipv4_src = old_ipv4_dst; // Swap source and destination
    let new_ipv4_dst = port_and_peer.peer_ip();
    let new_ipv4_len = old_ipv4_len - CdHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `Ipv4Hdr` in this scope.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, NET_SHRINK as usize + EthHdr::LEN)? };
    ipv4.set_version(4); // IPv4
    ipv4.set_ihl(5); // No options, 5 * 4 = 20 bytes
    ipv4.tos = old_ipv4_tos; // Preserve TOS/DSCP
    ipv4.set_total_len(new_ipv4_len);
    ipv4.set_id(old_ipv4_id); // Preserve ID
    ipv4.frag_off = old_ipv4_frag_off; // Preserve fragment flags
    ipv4.ttl = old_ipv4_ttl; // Preserve TTL exactly
    ipv4.proto = old_ipv4_proto; // Protocol is UDP
    ipv4.set_src_addr(new_ipv4_src);
    ipv4.set_dst_addr(new_ipv4_dst);
    ipv4.set_checksum(
        ChecksumUpdate::new(old_ipv4_check)
            .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
            .remove_u16(old_ipv4_len)
            .add_u32(u32::from_be_bytes(new_ipv4_dst.octets()))
            .add_u16(new_ipv4_len)
            .into_checksum(),
    );

    //
    // 3. UDP header
    //

    let new_udp_src = port_and_peer.allocation_port();
    let new_udp_dst = port_and_peer.peer_port();
    let new_udp_len = old_udp_len - CdHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `UdpHdr` in this scope.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    // TODO: Remove conditional checksums once we can test this fully in CI
    if old_udp_check == 0 || !crate::config::udp_checksum_enabled() {
        // No checksum is valid for UDP IPv4 - we didn't write it, but maybe a middlebox did
        udp.set_check(0);
    } else {
        let check = ChecksumUpdate::new(old_udp_check)
            .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
            .remove_u16(old_udp_src)
            .remove_u16(old_udp_dst)
            .remove_u16(old_udp_len)
            .remove_u16(old_udp_len)
            .remove_u16(channel_number)
            .remove_u16(channel_data_length)
            .add_u32(u32::from_be_bytes(new_ipv4_dst.octets()))
            .add_u16(new_udp_src)
            .add_u16(new_udp_dst)
            .add_u16(new_udp_len)
            .add_u16(new_udp_len)
            .into_checksum();

        if check == 0 {
            udp.set_check(0xFFFF); // Special case for zero checksum - write 0xFFFF to the wire
        } else {
            udp.set_check(check);
        }
    }

    adjust_head(ctx, NET_SHRINK)?;

    Ok(())
}

// Convert IPv4 to IPv6 and remove channel data header
#[inline(always)]
fn handle_ipv4_channel_to_ipv6_udp(
    ctx: &XdpContext,
    port_and_peer: &PortAndPeerV6,
) -> Result<(), Error> {
    const NET_EXPANSION: i32 = Ipv4Hdr::LEN as i32 - Ipv6Hdr::LEN as i32 + CdHdr::LEN as i32;

    adjust_head(ctx, NET_EXPANSION)?;

    // Now read the old packet data from its NEW location
    let old_data_offset = (-NET_EXPANSION) as usize;

    // SAFETY: Offset points to the start of the Ethernet header.
    let old_eth = unsafe { ref_at::<EthHdr>(ctx, old_data_offset)? };
    let old_dst_mac = old_eth.dst_addr;
    let old_src_mac = old_eth.src_addr;

    // SAFETY: Offset points to the start of the IPv4 header.
    let old_ipv4 = unsafe { ref_at::<Ipv4Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
    let old_ipv4_src = old_ipv4.src_addr();
    let old_ipv4_dst = old_ipv4.dst_addr();
    let old_ipv4_tos = old_ipv4.tos;
    let old_ipv4_ttl = old_ipv4.ttl;
    let old_ipv4_proto = old_ipv4.proto;

    // SAFETY: Offset points to the start of the UDP header.
    let old_udp = unsafe { ref_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN)? };
    let old_udp_len = old_udp.len();
    let old_udp_src = old_udp.source();
    let old_udp_dst = old_udp.dest();
    let old_udp_check = old_udp.check();

    // Refuse to compute full UDP checksum.
    // We forged these packets, so something's wrong if this is zero.
    if old_udp_check == 0 {
        return Err(Error::Ipv4ChecksumMissing);
    }

    // SAFETY: Offset points to the start of the channel data header.
    let old_cd = unsafe {
        ref_at::<CdHdr>(
            ctx,
            old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN,
        )?
    };
    let channel_number = u16::from_be_bytes(old_cd.number);
    let channel_data_length = u16::from_be_bytes(old_cd.length);

    //
    // 1. Ethernet header
    //

    // SAFETY: This is the only mutable instance of `EthHdr` in this scope.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
    eth.dst_addr = old_src_mac; // Swap MACs
    eth.src_addr = old_dst_mac;
    eth.ether_type = EtherType::Ipv6; // Change to IPv6

    //
    // 2. IPv6 header
    //

    // Get the learned IPv6 address for our interface
    let interface_addr = INT_ADDR_V6
        .get_ptr_mut(0)
        .ok_or(Error::InterfaceIpv6AddressAccessFailed)?;

    // SAFETY: INT_ADDR_V6 is a PerCpuArray, so we can safely access it.
    let new_ipv6_src = unsafe {
        (*interface_addr)
            .get()
            .ok_or(Error::InterfaceIpv6AddressNotLearned)?
    };

    let new_ipv6_dst = port_and_peer.peer_ip();
    let new_udp_len = old_udp_len - CdHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `Ipv6Hdr` in this scope.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    ipv6.set_version(6); // IPv6
    ipv6.set_priority(old_ipv4_tos);
    ipv6.flow_label = [0, 0, 0];
    ipv6.set_payload_len(new_udp_len);
    ipv6.next_hdr = old_ipv4_proto;
    ipv6.hop_limit = old_ipv4_ttl;
    ipv6.set_src_addr(new_ipv6_src);
    ipv6.set_dst_addr(new_ipv6_dst);

    //
    // 3. UDP header
    //
    let new_udp_src = port_and_peer.allocation_port();
    let new_udp_dst = port_and_peer.peer_port();

    // SAFETY: This is the only mutable instance of `UdpHdr` in this scope.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    // TODO: Remove conditional checksums once we can test this fully in CI
    if !crate::config::udp_checksum_enabled() {
        udp.set_check(0);
    } else {
        let check = ChecksumUpdate::new(old_udp_check)
            .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
            .remove_u32(u32::from_be_bytes(old_ipv4_dst.octets()))
            .remove_u16(old_udp_src)
            .remove_u16(old_udp_dst)
            .remove_u16(old_udp_len)
            .remove_u16(old_udp_len)
            .remove_u16(channel_number)
            .remove_u16(channel_data_length)
            .add_u128(u128::from_be_bytes(new_ipv6_src.octets()))
            .add_u128(u128::from_be_bytes(new_ipv6_dst.octets()))
            .add_u16(new_udp_src)
            .add_u16(new_udp_dst)
            .add_u16(new_udp_len)
            .add_u16(new_udp_len)
            .into_checksum();

        if check == 0 {
            udp.set_check(0xFFFF); // Special case for zero checksum - write 0xFFFF to the wire
        } else {
            udp.set_check(check);
        }
    }

    Ok(())
}

#[inline(always)]
fn handle_ipv6_udp_to_ipv6_channel(
    ctx: &XdpContext,
    client_and_channel: &ClientAndChannelV6,
) -> Result<(), Error> {
    // Expand by 4 bytes for channel data header
    const NET_EXPANSION: i32 = -(CdHdr::LEN as i32);

    adjust_head(ctx, NET_EXPANSION)?;

    // Now read the old packet data from its NEW location (shifted by 4 bytes)
    let old_data_offset = CdHdr::LEN;

    // SAFETY: Offset points to the start of the Ethernet header.
    let old_eth = unsafe { ref_at::<EthHdr>(ctx, old_data_offset)? };
    let old_eth_src = old_eth.src_addr;
    let old_eth_dst = old_eth.dst_addr;
    let old_eth_type = old_eth.ether_type;

    // SAFETY: Offset points to the start of the IPv6 header.
    let old_ipv6 = unsafe { ref_at::<Ipv6Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
    let old_ipv6_src = old_ipv6.src_addr();
    let old_ipv6_dst = old_ipv6.dst_addr();
    let old_ipv6_len = old_ipv6.payload_len();
    let old_ipv6_priority = old_ipv6.priority();
    let old_ipv6_flow_label = old_ipv6.flow_label;
    let old_ipv6_next_hdr = old_ipv6.next_hdr;
    let old_ipv6_hop_limit = old_ipv6.hop_limit;

    // SAFETY: Offset points to the start of the UDP header.
    let old_udp = unsafe { ref_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv6Hdr::LEN)? };
    let old_udp_src = old_udp.source();
    let old_udp_dst = old_udp.dest();
    let old_udp_len = old_udp.len();
    let old_udp_check = old_udp.check();

    // Write headers at new positions

    //
    // 1. Ethernet header
    //

    // SAFETY: This is the only mutable instance of `EthHdr` in this scope.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
    eth.src_addr = old_eth_dst; // Swap source and destination
    eth.dst_addr = old_eth_src;
    eth.ether_type = old_eth_type;

    //
    // 2. IPv6 header
    //
    let new_ipv6_src = old_ipv6_dst;
    let new_ipv6_dst = client_and_channel.client_ip();
    let new_ipv6_len = old_ipv6_len + CdHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `Ipv6Hdr` in this scope.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    // Set fields explicitly to avoid reading potentially corrupted memory
    ipv6.set_version(6); // IPv6
    ipv6.set_priority(old_ipv6_priority);
    ipv6.flow_label = old_ipv6_flow_label;
    ipv6.set_payload_len(new_ipv6_len);
    ipv6.next_hdr = old_ipv6_next_hdr;
    ipv6.hop_limit = old_ipv6_hop_limit;
    ipv6.set_src_addr(new_ipv6_src);
    ipv6.set_dst_addr(new_ipv6_dst);

    //
    // 3. UDP header
    //
    let channel_number = client_and_channel.channel();
    let channel_data_length = old_udp_len - UdpHdr::LEN as u16;
    let new_udp_len = old_udp_len + CdHdr::LEN as u16;
    let new_udp_src = 3478_u16;
    let new_udp_dst = client_and_channel.client_port();

    // SAFETY: This is the only mutable instance of `UdpHdr` in this scope.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    // TODO: Remove conditional checksums once we can test this fully in CI
    if !crate::config::udp_checksum_enabled() {
        udp.set_check(0);
    } else {
        let check = ChecksumUpdate::new(old_udp_check)
            .remove_u128(u128::from_be_bytes(old_ipv6_src.octets()))
            .remove_u16(old_udp_src)
            .remove_u16(old_udp_dst)
            .remove_u16(old_udp_len)
            .remove_u16(old_udp_len)
            .add_u128(u128::from_be_bytes(new_ipv6_dst.octets()))
            .add_u16(new_udp_src)
            .add_u16(new_udp_dst)
            .add_u16(new_udp_len)
            .add_u16(new_udp_len)
            .add_u16(channel_number)
            .add_u16(channel_data_length)
            .into_checksum();

        if check == 0 {
            udp.set_check(0xFFFF); // Special case for zero checksum - write 0xFFFF to the wire
        } else {
            udp.set_check(check);
        }
    }

    //
    // 4. Channel data header
    //

    // SAFETY: This is the only mutable instance of `CdHdr` in this scope.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };
    cd.number = channel_number.to_be_bytes();
    cd.length = channel_data_length.to_be_bytes();

    Ok(())
}

// Convert IPv6 to IPv4 and add channel data
#[inline(always)]
fn handle_ipv6_udp_to_ipv4_channel(
    ctx: &XdpContext,
    client_and_channel: &ClientAndChannelV4,
) -> Result<(), Error> {
    // 40 - 20 - 4 = 16 bytes shrink
    const NET_SHRINK: i32 = Ipv6Hdr::LEN as i32 - Ipv4Hdr::LEN as i32 - CdHdr::LEN as i32;

    // SAFETY: Offset points to the start of the Ethernet header.
    let old_eth = unsafe { ref_at::<EthHdr>(ctx, 0)? };
    let old_eth_src = old_eth.src_addr;
    let old_eth_dst = old_eth.dst_addr;

    // SAFETY: Offset points to the start of the IPv6 header.
    let old_ipv6 = unsafe { ref_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    let old_ipv6_src = old_ipv6.src_addr();
    let old_ipv6_dst = old_ipv6.dst_addr();
    let old_ipv6_priority = old_ipv6.priority();
    let old_ipv6_hop_limit = old_ipv6.hop_limit;
    let old_ipv6_next_hdr = old_ipv6.next_hdr;

    // SAFETY: Offset points to the start of the UDP header.
    let old_udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    let old_udp_src = old_udp.source();
    let old_udp_dst = old_udp.dest();
    let old_udp_len = old_udp.len();
    let old_udp_check = old_udp.check();

    //
    // 1. Ethernet header
    //

    // SAFETY: This is the only mutable instance of `EthHdr` in this scope.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, NET_SHRINK as usize)? };
    eth.src_addr = old_eth_dst; // Swap source and destination
    eth.dst_addr = old_eth_src;
    eth.ether_type = EtherType::Ipv4; // Change to IPv4

    //
    // 2. IPv6 -> IPv4 header
    //

    // Get the learned IPv4 address for our interface
    let interface_addr = INT_ADDR_V4
        .get_ptr_mut(0)
        .ok_or(Error::InterfaceIpv4AddressAccessFailed)?;

    // SAFETY: INT_ADDR_V4 is a PerCpuArray, so we can safely access it.
    let new_ipv4_src = unsafe {
        (*interface_addr)
            .get()
            .ok_or(Error::InterfaceIpv4AddressNotLearned)?
    };

    let new_ipv4_dst = client_and_channel.client_ip();
    let new_udp_len = old_udp_len + CdHdr::LEN as u16;
    let new_ipv4_len = Ipv4Hdr::LEN as u16 + new_udp_len;

    // SAFETY: This is the only mutable instance of `Ipv4Hdr` in this scope.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, NET_SHRINK as usize + EthHdr::LEN)? };
    ipv4.set_version(4);
    ipv4.set_ihl(5); // No options
    ipv4.tos = old_ipv6_priority;
    ipv4.set_total_len(new_ipv4_len);
    ipv4.set_id(0); // Default ID
    ipv4.frag_off = 0x4000_u16.to_be_bytes(); // Don't fragment
    ipv4.ttl = old_ipv6_hop_limit; // Preserve hop limit
    ipv4.proto = old_ipv6_next_hdr; // Preserve protocol
    ipv4.set_src_addr(new_ipv4_src);
    ipv4.set_dst_addr(new_ipv4_dst);

    // Calculate fresh checksum
    let check = checksum::new_ipv4(ipv4);
    ipv4.set_checksum(check);

    //
    // 3. UDP header
    //

    let new_udp_src = 3478_u16; // Fixed source port for TURN
    let new_udp_dst = client_and_channel.client_port();
    let channel_number = client_and_channel.channel();
    let channel_data_length = old_udp_len - UdpHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `UdpHdr` in this scope.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    // TODO: Remove conditional checksums once we can test this fully in CI
    if !crate::config::udp_checksum_enabled() {
        udp.set_check(0);
    } else {
        let check = ChecksumUpdate::new(old_udp_check)
            .remove_u128(u128::from_be_bytes(old_ipv6_src.octets()))
            .remove_u128(u128::from_be_bytes(old_ipv6_dst.octets()))
            .remove_u16(old_udp_src)
            .remove_u16(old_udp_dst)
            .remove_u16(old_udp_len)
            .remove_u16(old_udp_len)
            .add_u32(u32::from_be_bytes(new_ipv4_src.octets()))
            .add_u32(u32::from_be_bytes(new_ipv4_dst.octets()))
            .add_u16(new_udp_src)
            .add_u16(new_udp_dst)
            .add_u16(new_udp_len)
            .add_u16(new_udp_len)
            .add_u16(channel_number)
            .add_u16(channel_data_length)
            .into_checksum();

        if check == 0 {
            udp.set_check(0xFFFF); // Special case for zero checksum - write 0xFFFF to the wire
        } else {
            udp.set_check(check);
        }
    }

    //
    // 4. Channel data header
    //

    // SAFETY: This is the only mutable instance of `CdHdr` in this scope.
    let cd = unsafe {
        ref_mut_at::<CdHdr>(
            ctx,
            NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN,
        )?
    };
    cd.number = channel_number.to_be_bytes();
    cd.length = channel_data_length.to_be_bytes();

    adjust_head(ctx, NET_SHRINK)?;

    Ok(())
}

#[inline(always)]
fn handle_ipv6_channel_to_ipv6_udp(
    ctx: &XdpContext,
    port_and_peer: &PortAndPeerV6,
) -> Result<(), Error> {
    const NET_SHRINK: i32 = CdHdr::LEN as i32; // Shrink by 4 bytes for channel data header

    // SAFETY: Offset points to the start of the Ethernet header.
    let old_eth = unsafe { ref_at::<EthHdr>(ctx, 0)? };
    let old_eth_src = old_eth.src_addr;
    let old_eth_dst = old_eth.dst_addr;
    let old_eth_type = old_eth.ether_type;

    // SAFETY: Offset points to the start of the IPv6 header.
    let old_ipv6 = unsafe { ref_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    let old_ipv6_src = old_ipv6.src_addr();
    let old_ipv6_dst = old_ipv6.dst_addr();
    let old_ipv6_len = old_ipv6.payload_len();
    let old_ipv6_priority = old_ipv6.priority();
    let old_ipv6_flow_label = old_ipv6.flow_label;
    let old_ipv6_next_hdr = old_ipv6.next_hdr;
    let old_ipv6_hop_limit = old_ipv6.hop_limit;

    // SAFETY: Offset points to the start of the UDP header.
    let old_udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    let old_udp_src = old_udp.source();
    let old_udp_dst = old_udp.dest();
    let old_udp_len = old_udp.len();
    let old_udp_check = old_udp.check();

    // SAFETY: Offset points to the start of the channel data header.
    let old_cd = unsafe { ref_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };
    let channel_number = u16::from_be_bytes(old_cd.number);
    let channel_data_length = u16::from_be_bytes(old_cd.length);

    //
    // 1. Ethernet header
    //

    // SAFETY: This is the only mutable instance of `EthHdr` in this scope.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, NET_SHRINK as usize)? };
    eth.src_addr = old_eth_dst; // Swap source and destination
    eth.dst_addr = old_eth_src;
    eth.ether_type = old_eth_type;

    //
    // 2. IPv6 header
    //

    let new_ipv6_src = old_ipv6_dst; // Swap source and destination
    let new_ipv6_dst = port_and_peer.peer_ip();
    let new_ipv6_len = old_ipv6_len - CdHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `Ipv6Hdr` in this scope.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, NET_SHRINK as usize + EthHdr::LEN)? };
    ipv6.set_version(6); // IPv6
    ipv6.set_priority(old_ipv6_priority);
    ipv6.flow_label = old_ipv6_flow_label;
    ipv6.set_payload_len(new_ipv6_len);
    ipv6.next_hdr = old_ipv6_next_hdr;
    ipv6.hop_limit = old_ipv6_hop_limit;
    ipv6.set_src_addr(new_ipv6_src);
    ipv6.set_dst_addr(new_ipv6_dst);

    //
    // 3. UDP header
    //
    let new_udp_src = port_and_peer.allocation_port();
    let new_udp_dst = port_and_peer.peer_port();
    let new_udp_len = old_udp_len - CdHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `UdpHdr` in this scope.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    // TODO: Remove conditional checksums once we can test this fully in CI
    if !crate::config::udp_checksum_enabled() {
        udp.set_check(0);
    } else {
        let check = ChecksumUpdate::new(old_udp_check)
            .remove_u128(u128::from_be_bytes(old_ipv6_src.octets()))
            .remove_u16(old_udp_src)
            .remove_u16(old_udp_dst)
            .remove_u16(old_udp_len)
            .remove_u16(old_udp_len)
            .remove_u16(channel_number)
            .remove_u16(channel_data_length)
            .add_u128(u128::from_be_bytes(new_ipv6_dst.octets()))
            .add_u16(new_udp_src)
            .add_u16(new_udp_dst)
            .add_u16(new_udp_len)
            .add_u16(new_udp_len)
            .into_checksum();

        if check == 0 {
            udp.set_check(0xFFFF); // Special case for zero checksum - write 0xFFFF to the wire
        } else {
            udp.set_check(check);
        }
    }

    adjust_head(ctx, NET_SHRINK)?;

    Ok(())
}

// Convert IPv6 to IPv4 and remove channel data
#[inline(always)]
fn handle_ipv6_channel_to_ipv4_udp(
    ctx: &XdpContext,
    port_and_peer: &PortAndPeerV4,
) -> Result<(), Error> {
    // Shrink by 24 bytes: 20 for the IP header diff and 4 for the removed channel data header
    const NET_SHRINK: i32 = Ipv6Hdr::LEN as i32 - Ipv4Hdr::LEN as i32 + CdHdr::LEN as i32;

    // SAFETY: Offset points to the start of the Ethernet header.
    let old_eth = unsafe { ref_at::<EthHdr>(ctx, 0)? };
    let old_eth_src = old_eth.src_addr;
    let old_eth_dst = old_eth.dst_addr;

    // SAFETY: Offset points to the start of the IPv6 header.
    let old_ipv6 = unsafe { ref_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    let old_ipv6_src = old_ipv6.src_addr();
    let old_ipv6_dst = old_ipv6.dst_addr();
    let old_ipv6_priority = old_ipv6.priority();
    let old_ipv6_hop_limit = old_ipv6.hop_limit;
    let old_ipv6_next_hdr = old_ipv6.next_hdr;

    // SAFETY: Offset points to the start of the UDP header.
    let old_udp = unsafe { ref_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    let old_udp_src = old_udp.source();
    let old_udp_dst = old_udp.dest();
    let old_udp_len = old_udp.len();
    let old_udp_check = old_udp.check();

    // SAFETY: Offset points to the start of the channel data header.
    let old_cd = unsafe { ref_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };
    let channel_number = u16::from_be_bytes(old_cd.number);
    let channel_data_length = u16::from_be_bytes(old_cd.length);

    //
    // 1. Ethernet header
    //

    // SAFETY: This is the only mutable instance of `EthHdr` in this scope.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, NET_SHRINK as usize)? };
    eth.src_addr = old_eth_dst; // Swap source and destination
    eth.dst_addr = old_eth_src;
    eth.ether_type = EtherType::Ipv4; // Change to IPv4

    //
    // 2. IPv6 -> IPv4 header
    //

    let interface_addr = INT_ADDR_V4
        .get_ptr_mut(0)
        .ok_or(Error::InterfaceIpv4AddressAccessFailed)?;

    // SAFETY: INT_ADDR_V4 is a PerCpuArray, so we can safely access it.
    let new_ipv4_src = unsafe {
        (*interface_addr)
            .get()
            .ok_or(Error::InterfaceIpv4AddressNotLearned)?
    };

    let new_ipv4_dst = port_and_peer.peer_ip();
    let new_ipv4_len = old_udp_len - CdHdr::LEN as u16 + Ipv4Hdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `Ipv4Hdr` in this scope.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, NET_SHRINK as usize + EthHdr::LEN)? };
    ipv4.set_version(4);
    ipv4.set_ihl(5); // No options
    ipv4.tos = old_ipv6_priority; // Copy TOS from IPv6
    ipv4.set_total_len(new_ipv4_len);
    ipv4.set_id(0); // Default ID
    ipv4.frag_off = 0x4000_u16.to_be_bytes(); // Don't fragment
    ipv4.ttl = old_ipv6_hop_limit; // Preserve TTL
    ipv4.proto = old_ipv6_next_hdr; // Copy protocol from IPv6
    ipv4.set_src_addr(new_ipv4_src);
    ipv4.set_dst_addr(new_ipv4_dst);

    // Calculate fresh checksum
    let check = checksum::new_ipv4(ipv4);
    ipv4.set_checksum(check);

    //
    // 3. UDP header
    //

    let new_udp_src = port_and_peer.allocation_port();
    let new_udp_dst = port_and_peer.peer_port();
    let new_udp_len = old_udp_len - CdHdr::LEN as u16;

    // SAFETY: This is the only mutable instance of `UdpHdr` in this scope.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    // TODO: Remove conditional checksums once we can test this fully in CI
    if !crate::config::udp_checksum_enabled() {
        udp.set_check(0);
    } else {
        let check = ChecksumUpdate::new(old_udp_check)
            .remove_u128(u128::from_be_bytes(old_ipv6_src.octets()))
            .remove_u128(u128::from_be_bytes(old_ipv6_dst.octets()))
            .remove_u16(old_udp_src)
            .remove_u16(old_udp_dst)
            .remove_u16(old_udp_len)
            .remove_u16(old_udp_len)
            .remove_u16(channel_number)
            .remove_u16(channel_data_length)
            .add_u32(u32::from_be_bytes(new_ipv4_src.octets()))
            .add_u32(u32::from_be_bytes(new_ipv4_dst.octets()))
            .add_u16(new_udp_src)
            .add_u16(new_udp_dst)
            .add_u16(new_udp_len)
            .add_u16(new_udp_len)
            .into_checksum();

        if check == 0 {
            udp.set_check(0xFFFF); // Special case for zero checksum - write 0xFFFF to the wire
        } else {
            udp.set_check(check);
        }
    }

    adjust_head(ctx, NET_SHRINK)?;

    Ok(())
}

#[inline(always)]
fn adjust_head(ctx: &XdpContext, size: i32) -> Result<(), Error> {
    // SAFETY: The attach mode and NIC driver support headroom adjustment by `size` bytes.
    let ret = unsafe { bpf_xdp_adjust_head(ctx.ctx, size) };
    if ret < 0 {
        return Err(Error::XdpAdjustHeadFailed(ret));
    }

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
