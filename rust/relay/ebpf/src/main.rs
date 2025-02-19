#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::TC_ACT_PIPE,
    macros::{classifier, map},
    maps::HashMap,
    programs::TcContext,
};
use aya_log_ebpf::info;

use core::{mem, net::SocketAddr};
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{IpProto, Ipv4Hdr},
    tcp::TcpHdr,
    udp::UdpHdr,
};

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

struct ChannelNumber(u16);
struct AllocationPort(u16);

#[map]
static CHANNEL_DATA_TO_UDP: HashMap<(SocketAddr, ChannelNumber), (AllocationPort, SocketAddr)> =
    HashMap::with_max_entries(1024, 0);

#[map]
static UDP_TO_CHANNEL_DATA: HashMap<(AllocationPort, SocketAddr), (ChannelNumber, SocketAddr)> =
    HashMap::with_max_entries(1024, 0);

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

    let ip_proto = unsafe { (*ipv4hdr).proto };
    let IpProto::Udp = ip_proto else {
        return Ok(TC_ACT_PIPE);
    };

    let udphdr: *const UdpHdr = ptr_at(&ctx, EthHdr::LEN + Ipv4Hdr::LEN)?;

    let source_port = u16::from_be(unsafe { (*udphdr).source });

    let udp_payload_offset = EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN;

    let first_byte_ptr = ptr_at::<u8>(&ctx, udp_payload_offset)?;
    let first_byte = unsafe { *first_byte_ptr };

    if !(64..=79).contains(&first_byte) {
        return Ok(TC_ACT_PIPE);
    }

    let Ok(payload_ptr) = ptr_at::<u16>(&ctx, udp_payload_offset) else {
        return Ok(TC_ACT_PIPE);
    };

    let channel_number = u16::from_be(unsafe { *payload_ptr });

    // info!(
    //     &ctx,
    //     "Channel data message: SRC IP: {:i}, SRC PORT: {}",
    //     source_addr,
    //     source_port,
    //     // channel_number
    // );

    Ok(TC_ACT_PIPE)
}
