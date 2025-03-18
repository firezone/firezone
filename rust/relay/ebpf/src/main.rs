#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::{TC_ACT_PIPE, TC_ACT_SHOT},
    helpers::bpf_redirect,
    macros::{classifier, map},
    maps::HashMap,
    programs::TcContext,
};
use aya_log_ebpf::*;
use firezone_relay_ebpf_shared::{ChannelNumber, ClientAndChannel, PortAndPeer, SocketAddrV4};

use core::mem;
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{IpProto, Ipv4Hdr},
    udp::UdpHdr,
};

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[map]
static CHANNELS_TO_UDP: HashMap<ClientAndChannel, PortAndPeer> = HashMap::with_max_entries(1024, 0);

// #[map]
// static UDP_TO_CHANNEL_DATA: HashMap<(AllocationPort, SocketAddr), (ChannelNumber, SocketAddr)> =
//     HashMap::with_max_entries(1024, 0);

#[classifier]
pub fn handle_turn(ctx: TcContext) -> i32 {
    match try_handle_turn(ctx) {
        Ok(ret) => ret,
        Err(()) => TC_ACT_PIPE,
    }
}

#[inline(always)]
fn ptr_at<T>(ctx: &TcContext, offset: usize) -> Result<*const T, ()> {
    let start = ctx.data();
    let end = ctx.data_end();
    let len = mem::size_of::<T>();

    if start + offset + len > end {
        return Err(());
    }

    Ok((start + offset) as *const T)
}

fn try_handle_turn(ctx: TcContext) -> Result<i32, ()> {
    let ethhdr: *const EthHdr = ptr_at(&ctx, 0)?;

    match unsafe { (*ethhdr).ether_type } {
        EtherType::Ipv4 => {}
        _ => return Ok(TC_ACT_PIPE),
    }

    let ipv4hdr: *const Ipv4Hdr = ptr_at(&ctx, EthHdr::LEN)?;
    let source_addr = u32::from_be(unsafe { (*ipv4hdr).src_addr });
    let tot_len = u16::from_be(unsafe { (*ipv4hdr).tot_len });

    let ip_proto = unsafe { (*ipv4hdr).proto };
    let IpProto::Udp = ip_proto else {
        return Ok(TC_ACT_PIPE);
    };

    let udphdr: *const UdpHdr = ptr_at(&ctx, EthHdr::LEN + Ipv4Hdr::LEN)?;

    let source_port = u16::from_be(unsafe { (*udphdr).source });
    let udp_payload_len = u16::from_be(unsafe { (*udphdr).len });

    if source_port == 3478 {
        // Handle channel data messages
        let udp_payload_offset = EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN;

        let first_byte_ptr = ptr_at::<u8>(&ctx, udp_payload_offset)?;
        let first_byte = unsafe { *first_byte_ptr };

        if !(64..=79).contains(&first_byte) {
            return Ok(TC_ACT_PIPE);
        }

        let Ok(cn_ptr) = ptr_at::<u16>(&ctx, udp_payload_offset) else {
            return Ok(TC_ACT_PIPE);
        };
        let Ok(length_ptr) = ptr_at::<u16>(&ctx, udp_payload_offset + 2) else {
            return Ok(TC_ACT_PIPE);
        };

        let channel_number = u16::from_be(unsafe { *cn_ptr });
        let length = u16::from_be(unsafe { *length_ptr });

        if udp_payload_offset + 4 + length as usize > ctx.data_end() {
            // warn!("Length of channel data message out of bounds");

            return Ok(TC_ACT_SHOT);
        }

        let binding = unsafe {
            CHANNELS_TO_UDP.get(&ClientAndChannel(
                SocketAddrV4 {
                    ipv4_address: source_addr,
                    port: source_port,
                },
                ChannelNumber(channel_number),
            ))
        };
        let Some(PortAndPeer(
            new_src_port,
            SocketAddrV4 {
                ipv4_address: dst_ip,
                port: dst_port,
            },
        )) = binding
        else {
            debug!(
                "No channel binding from {:i} port {} for channel {}",
                source_addr, source_port, channel_number,
            );

            return Ok(TC_ACT_SHOT);
        };

        info!(
            &ctx,
            "Redirecting message from {:i}:{} on channel {} to {:i}{} on port {}",
            source_addr,
            source_port,
            channel_number,
            *dst_ip,
            *dst_port,
            *new_src_port
        );

        unsafe { *ipv4hdr }.dst_addr = *dst_ip;
        unsafe { *udphdr }.source = *new_src_port;
        unsafe { *udphdr }.dest = *dst_port;

        // Remove the channel header
        ctx.adjust_room(-4, 0, 0);
        ctx.l3_csum_replace(
            EthHdr::LEN + mem::offset_of!(Ipv4Hdr, check),
            tot_len as u64,
            (tot_len - 4) as u64,
            0,
        );
        ctx.l4_csum_replace(
            EthHdr::LEN + Ipv4Hdr::LEN + mem::offset_of!(UdpHdr, check),
            udp_payload_len as u64,
            (udp_payload_len - 4) as u64,
            0,
        );

        let ingress_ifindex = unsafe { (*(ctx.skb.skb)).ingress_ifindex };

        Ok(unsafe { bpf_redirect(ingress_ifindex, 0) as i32 })
    } else {
        try_handle_peer(ctx)
    }
}

fn try_handle_peer(ctx: TcContext) -> Result<i32, ()> {
    Err(())
}
