pub use error::Error;

use aya_ebpf::{bindings::xdp_action, helpers::bpf_xdp_adjust_head, programs::XdpContext};
use aya_log_ebpf::*;
use channel_data::CdHdr;
use checksum::ChecksumUpdate;
use ebpf_shared::{ClientAndChannelV4, ClientAndChannelV6, PortAndPeerV4, PortAndPeerV6};
use error::SupportedChannel;
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{IpProto, Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};
use ref_mut_at::ref_mut_at;

mod channel_data;
mod channel_maps;
mod checksum;
mod error;
mod interface;
mod ref_mut_at;
mod stats;

/// Lower bound for TURN UDP ports
const LOWER_PORT: u16 = 49152;
/// Upper bound for TURN UDP ports
const UPPER_PORT: u16 = 65535;
/// Channel number start
const CHAN_START: u16 = 0x4000;
/// Channel number end
const CHAN_END: u16 = 0x7FFF;

#[inline(always)]
pub fn try_handle_turn(ctx: &XdpContext) -> Result<u32, Error> {
    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };

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
    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };

    if ipv4.proto != IpProto::Udp {
        return Err(Error::NotUdp);
    }

    if ipv4.ihl() != 5 {
        // IPv4 with options is not supported
        return Err(Error::Ipv4PacketWithOptions);
    }

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };
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
    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };

    if ipv6.next_hdr != IpProto::Udp {
        return Err(Error::NotUdp);
    }

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
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
fn try_handle_ipv4_udp_to_channel_data(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };

    let key = PortAndPeerV4::new(ipv4.src_addr(), udp.dest(), udp.source());

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(client_and_channel) = unsafe { channel_maps::UDP_TO_CHAN_44.get(&key) } {
        handle_ipv4_udp_to_ipv4_channel(ctx, client_and_channel)?;
        return Ok(());
    }

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(client_and_channel) = unsafe { channel_maps::UDP_TO_CHAN_46.get(&key) } {
        handle_ipv4_udp_to_ipv6_channel(ctx, client_and_channel)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Udp4ToChan))
}

#[inline(always)]
fn try_handle_ipv4_channel_data_to_udp(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN)? };

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
    if let Some(port_and_peer) = unsafe { channel_maps::CHAN_TO_UDP_44.get(&key) } {
        // IPv4 to IPv4 - existing logic
        handle_ipv4_channel_to_ipv4_udp(ctx, port_and_peer)?;
        return Ok(());
    }

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(port_and_peer) = unsafe { channel_maps::CHAN_TO_UDP_46.get(&key) } {
        handle_ipv4_channel_to_ipv6_udp(ctx, port_and_peer)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Chan4ToUdp))
}

#[inline(always)]
fn try_handle_ipv6_udp_to_channel_data(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };

    let key = PortAndPeerV6::new(ipv6.src_addr(), udp.dest(), udp.source());

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(client_and_channel) = unsafe { channel_maps::UDP_TO_CHAN_66.get(&key) } {
        handle_ipv6_udp_to_ipv6_channel(ctx, client_and_channel)?;
        return Ok(());
    }

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(client_and_channel) = unsafe { channel_maps::UDP_TO_CHAN_64.get(&key) } {
        handle_ipv6_udp_to_ipv4_channel(ctx, client_and_channel)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Udp6ToChan))
}

#[inline(always)]
fn try_handle_ipv6_channel_data_to_udp(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };

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
    if let Some(port_and_peer) = unsafe { channel_maps::CHAN_TO_UDP_66.get(&key) } {
        handle_ipv6_channel_to_ipv6_udp(ctx, port_and_peer)?;
        return Ok(());
    }

    // SAFETY: We only write to these using a single thread in userspace.
    if let Some(port_and_peer) = unsafe { channel_maps::CHAN_TO_UDP_64.get(&key) } {
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

    let (old_eth_src, old_eth_dst, old_eth_type) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, old_data_offset)? };
        (old_eth.src_addr, old_eth.dst_addr, old_eth.ether_type)
    };

    let (
        old_ipv4_src,
        old_ipv4_dst,
        old_ipv4_len,
        old_ipv4_check,
        old_ipv4_tos,
        old_ipv4_id,
        old_ipv4_frag_off,
        old_ipv4_ttl,
        old_ipv4_proto,
    ) = {
        // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
        let old_ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
        (
            old_ipv4.src_addr(),
            old_ipv4.dst_addr(),
            old_ipv4.total_len(),
            old_ipv4.checksum(),
            old_ipv4.tos,
            old_ipv4.id(),
            old_ipv4.frag_off,
            old_ipv4.ttl,
            old_ipv4.proto,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp =
            unsafe { ref_mut_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
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

    // Check for packet loop - would we be sending to ourselves?
    if new_ipv4_src == new_ipv4_dst {
        return Err(Error::PacketLoop);
    }

    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
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
            .into_ip_checksum(),
    );

    //
    // 3. UDP header
    //

    let new_udp_src = 3478_u16;
    let new_udp_dst = client_and_channel.client_port();
    let new_udp_len = old_udp_len + CdHdr::LEN as u16;
    let channel_number = client_and_channel.channel();
    let channel_data_length = old_udp_len - UdpHdr::LEN as u16;

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    if old_udp_check == 0 {
        // No checksum is valid for UDP IPv4 - we didn't write it, but maybe a middlebox did
        udp.set_check(0);
    } else {
        udp.set_check(
            ChecksumUpdate::new(old_udp_check)
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
                .into_udp_checksum(),
        );
    }

    //
    // 4. Channel data header
    //

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
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

    let (old_eth_src, old_eth_dst) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, old_data_offset)? };
        (old_eth.src_addr, old_eth.dst_addr)
    };

    let (old_ipv4_src, old_ipv4_dst, old_ipv4_len, old_ipv4_tos, old_ipv4_ttl, old_ipv4_proto) = {
        // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
        let old_ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
        (
            old_ipv4.src_addr(),
            old_ipv4.dst_addr(),
            old_ipv4.total_len(),
            old_ipv4.tos,
            old_ipv4.ttl,
            old_ipv4.proto,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp =
            unsafe { ref_mut_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    // Refuse to compute full UDP checksum.
    // We forged these packets, so something's wrong if this is zero.
    if old_udp_check == 0 {
        return Err(Error::UdpChecksumMissing);
    }

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
    eth.dst_addr = old_eth_src; // Swap source and destination
    eth.src_addr = old_eth_dst;
    eth.ether_type = EtherType::Ipv6; // Change to IPv6

    //
    // 2. IPv4 -> IPv6 header
    //

    let new_ipv6_src = interface::ipv6_address()?;
    let new_ipv6_dst = client_and_channel.client_ip();
    let new_ipv6_len = old_ipv4_len - Ipv4Hdr::LEN as u16 + CdHdr::LEN as u16;

    // Check for packet loop - would we be sending to ourselves?
    if new_ipv6_dst == new_ipv6_src {
        return Err(Error::PacketLoop);
    }

    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
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

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_check(
        ChecksumUpdate::new(old_udp_check)
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
            .into_udp_checksum(),
    );

    //
    // 4. Channel data header
    //

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
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

    let (old_eth_src, old_eth_dst, old_eth_type) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
        (old_eth.src_addr, old_eth.dst_addr, old_eth.ether_type)
    };

    let (
        old_ipv4_src,
        old_ipv4_dst,
        old_ipv4_len,
        old_ipv4_check,
        old_ipv4_tos,
        old_ipv4_id,
        old_ipv4_frag_off,
        old_ipv4_ttl,
        old_ipv4_proto,
    ) = {
        // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
        let old_ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };
        (
            old_ipv4.src_addr(),
            old_ipv4.dst_addr(),
            old_ipv4.total_len(),
            old_ipv4.checksum(),
            old_ipv4.tos,
            old_ipv4.id(),
            old_ipv4.frag_off,
            old_ipv4.ttl,
            old_ipv4.proto,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    let (channel_number, channel_data_length) = {
        // SAFETY: The offset must point to the start of a valid `CdHdr`.
        let old_cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN)? };
        (
            u16::from_be_bytes(old_cd.number),
            u16::from_be_bytes(old_cd.length),
        )
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
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

    // Check for packet loop - would we be sending to ourselves?
    if new_ipv4_src == new_ipv4_dst {
        return Err(Error::PacketLoop);
    }

    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
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
            .into_ip_checksum(),
    );

    //
    // 3. UDP header
    //

    let new_udp_src = port_and_peer.allocation_port();
    let new_udp_dst = port_and_peer.peer_port();
    let new_udp_len = old_udp_len - CdHdr::LEN as u16;

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    if old_udp_check == 0 {
        // No checksum is valid for UDP IPv4 - we didn't write it, but maybe a middlebox did
        udp.set_check(0);
    } else {
        udp.set_check(
            ChecksumUpdate::new(old_udp_check)
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
                .into_udp_checksum(),
        );
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

    let (old_src_mac, old_dst_mac) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, old_data_offset)? };
        (old_eth.src_addr, old_eth.dst_addr)
    };

    let (old_ipv4_src, old_ipv4_dst, old_ipv4_tos, old_ipv4_ttl, old_ipv4_proto) = {
        // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
        let old_ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
        (
            old_ipv4.src_addr(),
            old_ipv4.dst_addr(),
            old_ipv4.tos,
            old_ipv4.ttl,
            old_ipv4.proto,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp =
            unsafe { ref_mut_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    // Refuse to compute full UDP checksum.
    // We forged these packets, so something's wrong if this is zero.
    if old_udp_check == 0 {
        return Err(Error::UdpChecksumMissing);
    }

    let (channel_number, channel_data_length) = {
        // SAFETY: The offset must point to the start of a valid `CdHdr`.
        let old_cd = unsafe {
            ref_mut_at::<CdHdr>(
                ctx,
                old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN,
            )?
        };
        (
            u16::from_be_bytes(old_cd.number),
            u16::from_be_bytes(old_cd.length),
        )
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
    eth.dst_addr = old_src_mac; // Swap MACs
    eth.src_addr = old_dst_mac;
    eth.ether_type = EtherType::Ipv6; // Change to IPv6

    //
    // 2. IPv6 header
    //

    let new_ipv6_src = interface::ipv6_address()?;
    let new_ipv6_dst = port_and_peer.peer_ip();
    let new_udp_len = old_udp_len - CdHdr::LEN as u16;

    // Check for packet loop - would we be sending to ourselves?
    if new_ipv6_src == new_ipv6_dst {
        return Err(Error::PacketLoop);
    }

    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
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

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_check(
        ChecksumUpdate::new(old_udp_check)
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
            .into_udp_checksum(),
    );

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

    let (old_eth_src, old_eth_dst, old_eth_type) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, old_data_offset)? };
        (old_eth.src_addr, old_eth.dst_addr, old_eth.ether_type)
    };

    let (
        old_ipv6_src,
        old_ipv6_dst,
        old_ipv6_len,
        old_ipv6_priority,
        old_ipv6_flow_label,
        old_ipv6_hop_limit,
        old_ipv6_next_hdr,
    ) = {
        // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
        let old_ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
        (
            old_ipv6.src_addr(),
            old_ipv6.dst_addr(),
            old_ipv6.payload_len(),
            old_ipv6.priority(),
            old_ipv6.flow_label,
            old_ipv6.hop_limit,
            old_ipv6.next_hdr,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp =
            unsafe { ref_mut_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv6Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
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

    // Check for packet loop - would we be sending to ourselves?
    if new_ipv6_src == new_ipv6_dst {
        return Err(Error::PacketLoop);
    }

    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
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

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_check(
        ChecksumUpdate::new(old_udp_check)
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
            .into_udp_checksum(),
    );

    //
    // 4. Channel data header
    //

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
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

    let (old_eth_src, old_eth_dst) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
        (old_eth.src_addr, old_eth.dst_addr)
    };

    let (old_ipv6_src, old_ipv6_dst, old_ipv6_priority, old_ipv6_hop_limit, old_ipv6_next_hdr) = {
        // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
        let old_ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
        (
            old_ipv6.src_addr(),
            old_ipv6.dst_addr(),
            old_ipv6.priority(),
            old_ipv6.hop_limit,
            old_ipv6.next_hdr,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, NET_SHRINK as usize)? };
    eth.src_addr = old_eth_dst; // Swap source and destination
    eth.dst_addr = old_eth_src;
    eth.ether_type = EtherType::Ipv4; // Change to IPv4

    //
    // 2. IPv6 -> IPv4 header
    //

    let new_ipv4_src = interface::ipv4_address()?;
    let new_ipv4_dst = client_and_channel.client_ip();
    let new_udp_len = old_udp_len + CdHdr::LEN as u16;
    let new_ipv4_len = Ipv4Hdr::LEN as u16 + new_udp_len;

    // Check for packet loop - would we be sending to ourselves?
    if new_ipv4_dst == new_ipv4_src {
        return Err(Error::PacketLoop);
    }

    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
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

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_check(
        ChecksumUpdate::new(old_udp_check)
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
            .into_udp_checksum(),
    );

    //
    // 4. Channel data header
    //

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
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

    let (old_eth_src, old_eth_dst, old_eth_type) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
        (old_eth.src_addr, old_eth.dst_addr, old_eth.ether_type)
    };

    let (
        old_ipv6_src,
        old_ipv6_dst,
        old_ipv6_len,
        old_ipv6_priority,
        old_ipv6_flow_label,
        old_ipv6_hop_limit,
        old_ipv6_next_hdr,
    ) = {
        // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
        let old_ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
        (
            old_ipv6.src_addr(),
            old_ipv6.dst_addr(),
            old_ipv6.payload_len(),
            old_ipv6.priority(),
            old_ipv6.flow_label,
            old_ipv6.hop_limit,
            old_ipv6.next_hdr,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    let (channel_number, channel_data_length) = {
        // SAFETY: The offset must point to the start of a valid `CdHdr`.
        let old_cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };
        (
            u16::from_be_bytes(old_cd.number),
            u16::from_be_bytes(old_cd.length),
        )
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
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

    // Check for packet loop - would we be sending to ourselves?
    if new_ipv6_src == new_ipv6_dst {
        return Err(Error::PacketLoop);
    }

    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
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

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_check(
        ChecksumUpdate::new(old_udp_check)
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
            .into_udp_checksum(),
    );

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

    let (old_eth_src, old_eth_dst) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
        (old_eth.src_addr, old_eth.dst_addr)
    };

    let (old_ipv6_src, old_ipv6_dst, old_ipv6_priority, old_ipv6_hop_limit, old_ipv6_next_hdr) = {
        // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
        let old_ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
        (
            old_ipv6.src_addr(),
            old_ipv6.dst_addr(),
            old_ipv6.priority(),
            old_ipv6.hop_limit,
            old_ipv6.next_hdr,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    let (channel_number, channel_data_length) = {
        // SAFETY: The offset must point to the start of a valid `CdHdr`.
        let old_cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };
        (
            u16::from_be_bytes(old_cd.number),
            u16::from_be_bytes(old_cd.length),
        )
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, NET_SHRINK as usize)? };
    eth.src_addr = old_eth_dst; // Swap source and destination
    eth.dst_addr = old_eth_src;
    eth.ether_type = EtherType::Ipv4; // Change to IPv4

    //
    // 2. IPv6 -> IPv4 header
    //

    let new_ipv4_src = interface::ipv4_address()?;
    let new_ipv4_dst = port_and_peer.peer_ip();
    let new_ipv4_len = old_udp_len - CdHdr::LEN as u16 + Ipv4Hdr::LEN as u16;

    // Check for packet loop - would we be sending to ourselves?
    if new_ipv4_src == new_ipv4_dst {
        return Err(Error::PacketLoop);
    }

    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
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

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_check(
        ChecksumUpdate::new(old_udp_check)
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
            .into_udp_checksum(),
    );

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
