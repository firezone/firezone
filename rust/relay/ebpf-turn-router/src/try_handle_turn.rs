mod adjust_head;
mod channel_data;
mod checksum;
mod error;
mod from_ipv4_channel;
mod from_ipv4_udp;
mod from_ipv6_channel;
mod from_ipv6_udp;
mod interface;
mod ref_mut_at;
mod routing;
mod stats;

pub use adjust_head::adjust_head;
pub use error::Error;

use aya_ebpf::{bindings::xdp_action, programs::XdpContext};
use aya_log_ebpf::*;
use channel_data::CdHdr;
use ebpf_shared::{ClientAndChannelV4, ClientAndChannelV6, PortAndPeerV4, PortAndPeerV6};
use error::SupportedChannel;
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{IpProto, Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};
use ref_mut_at::ref_mut_at;

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

    let num_bytes = match eth.ether_type {
        EtherType::Ipv4 => try_handle_turn_ipv4(ctx)?,
        EtherType::Ipv6 => try_handle_turn_ipv6(ctx)?,
        _ => return Err(Error::NotIp),
    };
    stats::emit_data_relayed(ctx, num_bytes);

    // If we get to here, we modified the packet and need to send it back out again.
    Ok(xdp_action::XDP_TX)
}

#[inline(always)]
fn try_handle_turn_ipv4(ctx: &XdpContext) -> Result<u16, Error> {
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
        try_handle_from_ipv4_udp(ctx)?;

        return Ok(udp_payload_len);
    }

    if udp.dest() == 3478 {
        try_handle_from_ipv4_channel_data(ctx)?;

        return Ok(udp_payload_len - CdHdr::LEN as u16);
    }

    Err(Error::NotTurn)
}

#[inline(always)]
fn try_handle_turn_ipv6(ctx: &XdpContext) -> Result<u16, Error> {
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
        try_handle_from_ipv6_udp(ctx)?;

        return Ok(udp_payload_len);
    }

    if udp.dest() == 3478 {
        try_handle_from_ipv6_channel_data(ctx)?;

        return Ok(udp_payload_len - CdHdr::LEN as u16);
    }

    Err(Error::NotTurn)
}

#[inline(always)]
fn try_handle_from_ipv4_udp(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };

    let key = PortAndPeerV4::new(ipv4.src_addr(), udp.dest(), udp.source());

    if let Some(cc) = routing::get_client_and_channel_v4(key) {
        if cc.client_ip() == interface::ipv4_address()?
            && let Some(pp) = routing::get_port_and_peer_v4(cc)
        {
            from_ipv4_udp::to_ipv4_udp(ctx, &pp)?;
            return Ok(());
        }

        if cc.client_ip() == interface::ipv4_address()?
            && let Some(pp) = routing::get_port_and_peer_v6(cc)
        {
            from_ipv4_udp::to_ipv6_udp(ctx, &pp)?;
            return Ok(());
        }

        from_ipv4_udp::to_ipv4_channel(ctx, &cc)?;
        return Ok(());
    }

    if let Some(cc) = routing::get_client_and_channel_v6(key) {
        if cc.client_ip() == interface::ipv6_address()?
            && let Some(pp) = routing::get_port_and_peer_v6(cc)
        {
            from_ipv4_udp::to_ipv6_udp(ctx, &pp)?;
            return Ok(());
        }

        if cc.client_ip() == interface::ipv6_address()?
            && let Some(pp) = routing::get_port_and_peer_v4(cc)
        {
            from_ipv4_udp::to_ipv4_udp(ctx, &pp)?;
            return Ok(());
        }

        from_ipv4_udp::to_ipv6_channel(ctx, &cc)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Udp4ToChan))
}

#[inline(always)]
fn try_handle_from_ipv4_channel_data(ctx: &XdpContext) -> Result<(), Error> {
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

    if let Some(port_and_peer) = routing::get_port_and_peer_v4(key) {
        from_ipv4_channel::to_ipv4_udp(ctx, &port_and_peer)?;
        return Ok(());
    }

    if let Some(port_and_peer) = routing::get_port_and_peer_v6(key) {
        from_ipv4_channel::to_ipv6_udp(ctx, &port_and_peer)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Chan4ToUdp))
}

#[inline(always)]
fn try_handle_from_ipv6_udp(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };

    let key = PortAndPeerV6::new(ipv6.src_addr(), udp.dest(), udp.source());

    if let Some(client_and_channel) = routing::get_client_and_channel_v6(key) {
        from_ipv6_udp::to_ipv6_channel(ctx, &client_and_channel)?;
        return Ok(());
    }

    if let Some(client_and_channel) = routing::get_client_and_channel_v4(key) {
        from_ipv6_udp::to_ipv4_channel(ctx, &client_and_channel)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Udp6ToChan))
}

#[inline(always)]
fn try_handle_from_ipv6_channel_data(ctx: &XdpContext) -> Result<(), Error> {
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

    if let Some(port_and_peer) = routing::get_port_and_peer_v6(key) {
        from_ipv6_channel::to_ipv6_udp(ctx, &port_and_peer)?;
        return Ok(());
    }

    if let Some(port_and_peer) = routing::get_port_and_peer_v4(key) {
        from_ipv6_channel::to_ipv4_udp(ctx, &port_and_peer)?;
        return Ok(());
    }

    Err(Error::NoEntry(SupportedChannel::Chan6ToUdp))
}
