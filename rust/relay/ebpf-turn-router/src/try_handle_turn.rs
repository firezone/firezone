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

use core::net::IpAddr;

pub use adjust_head::adjust_head;
pub use error::Error;

use aya_ebpf::programs::XdpContext;
use aya_log_ebpf::*;
use channel_data::CdHdr;
use ebpf_shared::{
    ClientAndChannel, ClientAndChannelV4, ClientAndChannelV6, PortAndPeer, PortAndPeerV4,
    PortAndPeerV6,
};
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
pub fn try_handle_turn(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };

    let num_bytes = match eth.ether_type {
        EtherType::Ipv4 => try_handle_turn_ipv4(ctx)?,
        EtherType::Ipv6 => try_handle_turn_ipv6(ctx)?,
        _ => return Err(Error::NotIp),
    };
    stats::emit_data_relayed(ctx, num_bytes);

    Ok(())
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
        target: "eBPF",
        "<== new packet from {:i}:{} for {:i}:{} with UDP payload {}",
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
        target: "eBPF",
        "<== new packet from {:i}:{} for {:i}:{} with UDP payload {}",
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

    let pp = PortAndPeerV4::new(ipv4.src_addr(), udp.dest(), udp.source());
    let cc = routing::get_client_and_channel(pp)?;

    aya_log_ebpf::trace!(
        ctx,
        target: "eBPF",
        "Routing packet from {:i}:{} on allocation {} to {:i}:{} on channel {}",
        pp.peer_ip(),
        pp.peer_port(),
        pp.allocation_port(),
        cc.client_ip(),
        cc.client_port(),
        cc.channel()
    );

    match cc {
        ClientAndChannel::V4(cc) => from_ipv4_udp::to_ipv4_channel(ctx, &cc)?,
        ClientAndChannel::V6(cc) => from_ipv4_udp::to_ipv6_channel(ctx, &cc)?,
    }

    Ok(())
}

#[inline(always)]
fn try_handle_from_ipv4_channel_data(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN)? };

    let channel_number = cd.number();

    if !(CHAN_START..=CHAN_END).contains(&channel_number) {
        return Err(Error::NotAChannelDataMessage);
    }

    let channel_data_len = cd.length();
    let expected_channel_data_len = udp.len() - UdpHdr::LEN as u16 - CdHdr::LEN as u16;

    // This can happen if we receive packets formed via GSO, like on a loopback interface.
    if channel_data_len != expected_channel_data_len {
        return Err(Error::BadChannelDataLength);
    }

    let cc = ClientAndChannelV4::new(ipv4.src_addr(), udp.source(), channel_number);
    let pp = routing::get_port_and_peer(cc)?;

    aya_log_ebpf::trace!(
        ctx,
        target: "eBPF",
        "Routing packet from {:i}:{} on channel {} to {:i}:{} on allocation {}",
        cc.client_ip(),
        cc.client_port(),
        cc.channel(),
        pp.peer_ip(),
        pp.peer_port(),
        pp.allocation_port(),
    );

    if is_interface_ip(pp.peer_ip())? {
        let pp = pp.flip_ports();
        let cc = routing::get_client_and_channel(pp)?;

        aya_log_ebpf::trace!(
            ctx,
            target: "eBPF",
            "Routing packet from {:i}:{} on allocation {} to {:i}:{} on channel {}",
            pp.peer_ip(),
            pp.peer_port(),
            pp.allocation_port(),
            cc.client_ip(),
            cc.client_port(),
            cc.channel()
        );

        match cc {
            ClientAndChannel::V4(cc) => from_ipv4_channel::to_ipv4_channel(ctx, &cc)?,
            ClientAndChannel::V6(cc) => from_ipv4_channel::to_ipv6_channel(ctx, &cc)?,
        }

        return Ok(());
    }

    match pp {
        PortAndPeer::V4(pp) => from_ipv4_channel::to_ipv4_udp(ctx, &pp)?,
        PortAndPeer::V6(pp) => from_ipv4_channel::to_ipv6_udp(ctx, &pp)?,
    }

    Ok(())
}

#[inline(always)]
fn try_handle_from_ipv6_udp(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };

    let pp = PortAndPeerV6::new(ipv6.src_addr(), udp.dest(), udp.source());
    let cc = routing::get_client_and_channel(pp)?;

    aya_log_ebpf::trace!(
        ctx,
        target: "eBPF",
        "Routing packet from {:i}:{} on allocation {} to {:i}:{} on channel {}",
        pp.peer_ip(),
        pp.peer_port(),
        pp.allocation_port(),
        cc.client_ip(),
        cc.client_port(),
        cc.channel()
    );

    match cc {
        ClientAndChannel::V4(cc) => from_ipv6_udp::to_ipv4_channel(ctx, &cc)?,
        ClientAndChannel::V6(cc) => from_ipv6_udp::to_ipv6_channel(ctx, &cc)?,
    }

    Ok(())
}

#[inline(always)]
fn try_handle_from_ipv6_channel_data(ctx: &XdpContext) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };

    let channel_number = cd.number();

    if !(CHAN_START..=CHAN_END).contains(&channel_number) {
        return Err(Error::NotAChannelDataMessage);
    }

    let channel_data_len = u16::from_be_bytes(cd.length);
    let expected_channel_data_len = udp.len() - UdpHdr::LEN as u16 - CdHdr::LEN as u16;

    // This can happen if we receive packets formed via GSO, like on a loopback interface.
    if channel_data_len != expected_channel_data_len {
        return Err(Error::BadChannelDataLength);
    }

    let cc = ClientAndChannelV6::new(ipv6.src_addr(), udp.source(), cd.number());
    let pp = routing::get_port_and_peer(cc)?;

    aya_log_ebpf::trace!(
        ctx,
        target: "eBPF",
        "Routing packet from {:i}:{} on channel {} to {:i}:{} on allocation {}",
        cc.client_ip(),
        cc.client_port(),
        cc.channel(),
        pp.peer_ip(),
        pp.peer_port(),
        pp.allocation_port(),
    );

    if is_interface_ip(pp.peer_ip())? {
        let pp = pp.flip_ports();
        let cc = routing::get_client_and_channel(pp)?;

        aya_log_ebpf::trace!(
            ctx,
            target: "eBPF",
            "Routing packet from {:i}:{} on allocation {} to {:i}:{} on channel {}",
            pp.peer_ip(),
            pp.peer_port(),
            pp.allocation_port(),
            cc.client_ip(),
            cc.client_port(),
            cc.channel()
        );

        match cc {
            ClientAndChannel::V4(cc) => from_ipv6_channel::to_ipv4_channel(ctx, &cc)?,
            ClientAndChannel::V6(cc) => from_ipv6_channel::to_ipv6_channel(ctx, &cc)?,
        }

        return Ok(());
    }

    match pp {
        PortAndPeer::V4(pp) => from_ipv6_channel::to_ipv4_udp(ctx, &pp)?,
        PortAndPeer::V6(pp) => from_ipv6_channel::to_ipv6_udp(ctx, &pp)?,
    }

    Ok(())
}

#[inline(always)]
fn is_interface_ip(ip: IpAddr) -> Result<bool, Error> {
    let ipv4_interface = interface::ipv4_address()?;
    let ipv6_interface = interface::ipv6_address()?;

    Ok(ip == ipv4_interface || ip == ipv6_interface)
}
