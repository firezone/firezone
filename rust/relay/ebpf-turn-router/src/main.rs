#![cfg_attr(target_arch = "bpf", no_std)]
#![cfg_attr(target_arch = "bpf", no_main)]

use crate::error::Error;
use crate::slice_mut_at::slice_mut_at;
use aya_ebpf::{
    bindings::xdp_action,
    macros::{map, xdp},
    maps::HashMap,
    programs::XdpContext,
};
use aya_log_ebpf::*;
use channel_data::ChannelData;
use ebpf_shared::{ClientAndChannelV4, PortAndPeerV4};
use eth2::Eth2;
use etherparse::{EtherType, IpNumber};
use ip4::Ip4;
use move_headers::{add_channel_data_header_ipv4, remove_channel_data_header_ipv4};
use udp::Udp;

mod channel_data;
mod checksum;
mod config;
mod error;
mod eth2;
mod ip4;
mod move_headers;
mod slice_mut_at;
mod udp;

pub const CHANNEL_DATA_HEADER_LEN: usize = 4;

/// Channel mappings from an IPv4 socket + channel number to an IPv4 socket + port.
///
/// TODO: Update flags to `BPF_F_NO_PREALLOC` to guarantee atomicity? Needs research.
#[map]
static CHAN_TO_UDP_44: HashMap<ClientAndChannelV4, PortAndPeerV4> =
    HashMap::with_max_entries(0x100000, 0);
#[map]
static UDP_TO_CHAN_44: HashMap<PortAndPeerV4, ClientAndChannelV4> =
    HashMap::with_max_entries(0x100000, 0);

#[xdp]
pub fn handle_turn(ctx: XdpContext) -> u32 {
    try_handle_turn(&ctx).unwrap_or_else(|e| {
        let action = e.xdp_action();

        debug!(&ctx, "Failed to handle packet {}; action = {}", e, action);

        action
    })
}

#[inline(always)]
fn try_handle_turn(ctx: &XdpContext) -> Result<u32, Error> {
    let eth = Eth2::parse(ctx)?;

    match eth.ether_type() {
        EtherType::IPV4 => try_handle_turn_ipv4(ctx),
        EtherType::IPV6 => try_handle_turn_ipv6(ctx),
        _ => Ok(xdp_action::XDP_PASS),
    }
}

#[inline(always)]
fn try_handle_turn_ipv4(ctx: &XdpContext) -> Result<u32, Error> {
    let ipv4 = Ip4::parse(ctx)?;

    if ipv4.protocol() != IpNumber::UDP {
        return Ok(xdp_action::XDP_PASS);
    }

    let udp = Udp::parse(ctx)?; // TODO: Change the API so we parse the UDP header _from_ the ipv4 struct?

    trace!(ctx, "New packet from {:i}:{}", ipv4.src(), udp.src());

    if udp.dst() == 3478 {
        try_handle_ipv4_channel_data_to_udp(ctx, ipv4, udp)
    } else {
        try_handle_ipv4_udp_to_channel_data(ctx, ipv4, udp)
    }
}

fn try_handle_ipv4_channel_data_to_udp(
    ctx: &XdpContext,
    ipv4: Ip4,
    udp: Udp,
) -> Result<u32, Error> {
    let cd = ChannelData::parse(ctx)?;

    // SAFETY: ???
    let maybe_peer =
        unsafe { CHAN_TO_UDP_44.get(&ClientAndChannelV4::new(ipv4.src(), udp.src(), cd.number())) };
    let Some(port_and_peer) = maybe_peer else {
        debug!(
            ctx,
            "No channel binding from {:i}:{} for channel {}",
            ipv4.src(),
            udp.src(),
            cd.number(),
        );

        return Ok(xdp_action::XDP_PASS);
    };

    let new_src = ipv4.dst(); // The IP we received the packet on will be the new source IP.
    let new_ipv4_total_len = ipv4.total_len() - CHANNEL_DATA_HEADER_LEN as u16;
    let pseudo_header = ipv4.update(new_src, port_and_peer.peer_ip(), new_ipv4_total_len);

    let new_udp_len = udp.len() - CHANNEL_DATA_HEADER_LEN as u16;
    udp.update(
        pseudo_header,
        port_and_peer.allocation_port(),
        port_and_peer.peer_port(),
        new_udp_len,
    );

    remove_channel_data_header_ipv4(ctx);

    Ok(xdp_action::XDP_TX)
}

#[inline(always)]
fn try_handle_ipv4_udp_to_channel_data(
    ctx: &XdpContext,
    ipv4: Ip4,
    udp: Udp,
) -> Result<u32, Error> {
    let maybe_client =
        unsafe { UDP_TO_CHAN_44.get(&PortAndPeerV4::new(ipv4.src(), udp.dst(), udp.src())) };
    let Some(client_and_channel) = maybe_client else {
        debug!(
            ctx,
            "No channel binding from {:i}:{} on allocation {}",
            ipv4.src(),
            udp.src(),
            udp.dst(),
        );

        return Ok(xdp_action::XDP_PASS);
    };

    let new_src = ipv4.dst(); // The IP we received the packet on will be the new source IP.
    let new_ipv4_total_len = ipv4.total_len() + CHANNEL_DATA_HEADER_LEN as u16;
    let pseudo_header = ipv4.update(new_src, client_and_channel.client_ip(), new_ipv4_total_len);

    let udp_len = udp.len();
    let new_udp_len = udp_len + CHANNEL_DATA_HEADER_LEN as u16;
    udp.update(
        pseudo_header,
        3478,
        client_and_channel.client_port(),
        new_udp_len,
    );

    let cd_num = client_and_channel.channel().to_be_bytes();
    let cd_len = udp_len.to_be_bytes();

    let channel_data_header = [cd_num[0], cd_num[1], cd_len[0], cd_len[1]];

    add_channel_data_header_ipv4(ctx, channel_data_header);

    Ok(xdp_action::XDP_TX)
}

fn try_handle_turn_ipv6(_: &XdpContext) -> Result<u32, Error> {
    Ok(xdp_action::XDP_PASS)
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
