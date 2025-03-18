#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::{BPF_F_RECOMPUTE_CSUM, TC_ACT_PIPE, TC_ACT_SHOT},
    cty::c_void,
    helpers::{bpf_redirect, bpf_skb_store_bytes},
    macros::{classifier, map},
    maps::HashMap,
    programs::TcContext,
};
use aya_log_ebpf::*;
use firezone_relay_ebpf_shared::{ClientAndChannel, PortAndPeer};

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
static CHANNELS_TO_UDP: HashMap<ClientAndChannel, PortAndPeer> =
    HashMap::with_max_entries(0x1000, 0);

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
    let dest_port = u16::from_be(unsafe { (*udphdr).dest });
    let udp_payload_len = u16::from_be(unsafe { (*udphdr).len });

    trace!(&ctx, "New packet from {:i}:{}", source_addr, source_port);

    if dest_port == 3478 {
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
            warn!(&ctx, "Length of channel data message out of bounds");

            return Ok(TC_ACT_SHOT);
        }

        let client_and_channel = ClientAndChannel::new(source_addr, source_port, channel_number);

        let binding = unsafe { CHANNELS_TO_UDP.get(&client_and_channel) };
        let Some(port_and_peer) = binding else {
            debug!(
                &ctx,
                "No channel binding from {:x}:{:x} for channel {:x}",
                source_addr,
                source_port,
                channel_number,
            );

            return Ok(TC_ACT_SHOT);
        };

        unsafe { *ipv4hdr }.dst_addr = port_and_peer.dest_ip();
        unsafe { *ipv4hdr }.tot_len = (tot_len - 4).to_be();
        unsafe { *udphdr }.source = port_and_peer.allocation_port();
        unsafe { *udphdr }.dest = port_and_peer.dest_port();
        unsafe { *udphdr }.len = (udp_payload_len - 4).to_be();

        let Ok(encapsulated_data_ptr) = ptr_at::<u8>(&ctx, udp_payload_offset + 4) else {
            return Ok(TC_ACT_PIPE);
        };

        // NOTE: TC programs are not allowed to modify the packet so this fails. Need to use XDP instead ...
        unsafe {
            let ret = bpf_skb_store_bytes(
                ctx.skb.skb,
                udp_payload_offset as u32,
                encapsulated_data_ptr as *const c_void,
                (udp_payload_len - 4) as u32,
                BPF_F_RECOMPUTE_CSUM as u64,
            );

            if ret != 0 {
                return Err(());
            }
        }

        let ingress_ifindex = unsafe { (*(ctx.skb.skb)).ingress_ifindex };

        let res = unsafe { bpf_redirect(ingress_ifindex, 0) as i32 };

        info!(
            &ctx,
            "Redirecting message from {:i}:{} on channel {} to {:i}:{} on port {}; res = {}",
            source_addr,
            source_port,
            channel_number,
            port_and_peer.dest_ip(),
            port_and_peer.dest_port(),
            port_and_peer.allocation_port(),
            res
        );

        Ok(res)
    } else {
        try_handle_peer(ctx)
    }
}

fn try_handle_peer(ctx: TcContext) -> Result<i32, ()> {
    Err(())
}
