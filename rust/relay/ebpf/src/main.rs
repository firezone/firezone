#![cfg_attr(not(test), no_std)]
#![cfg_attr(not(test), no_main)]

use crate::error::Error;
use aya_ebpf::{
    bindings::xdp_action,
    cty::c_void,
    helpers::{bpf_xdp_adjust_head, bpf_xdp_load_bytes, bpf_xdp_store_bytes},
    macros::{map, xdp},
    maps::HashMap,
    programs::XdpContext,
};
use aya_log_ebpf::*;
use etherparse::{
    EtherType, Ethernet2Header, Ethernet2HeaderSlice, IpNumber, Ipv4Header, Ipv4HeaderSlice,
    Ipv6Header, UdpHeader, UdpHeaderSlice,
};
use etherparse_ext::{Ipv4HeaderSliceMut, UdpHeaderSliceMut};
use firezone_relay_ebpf_shared::{ClientAndChannel, PortAndPeer};

mod error;

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

#[xdp]
pub fn handle_turn(ctx: XdpContext) -> u32 {
    match try_handle_turn(&ctx) {
        Ok(ret) => ret,
        Err(e) => {
            debug!(&ctx, "Failed to handle packet {}", e);

            xdp_action::XDP_PASS // Re-consider this.
        }
    }
}

const CHANNEL_DATA_HEADER_LEN: usize = 4;

#[inline(always)]
fn try_handle_turn(ctx: &XdpContext) -> Result<u32, Error> {
    let ethhdr_slice = slice_mut_at::<{ Ethernet2Header::LEN }>(ctx, 0)?;
    let ethhdr = parse_eth(ethhdr_slice)?;

    match ethhdr.ether_type() {
        EtherType::IPV4 => {}
        _ => return Ok(xdp_action::XDP_PASS),
    }

    let ipv4hdr_slice = slice_mut_at::<{ Ipv4Header::MIN_LEN }>(ctx, Ethernet2Header::LEN)?;
    let ipv4hdr = parse_ipv4(ipv4hdr_slice)?;

    let src_addr = u32::from_be_bytes(ipv4hdr.source());
    let dst_addr = u32::from_be_bytes(ipv4hdr.destination());
    let tot_len = ipv4hdr.total_len();
    let ipv4_checksum = ipv4hdr.header_checksum();

    // IPv4 packets with options are handled in user-space.
    if usize::from(ipv4hdr.ihl() * 4) != Ipv4Header::MIN_LEN {
        return Ok(xdp_action::XDP_PASS);
    }

    let IpNumber::UDP = ipv4hdr.protocol() else {
        return Ok(xdp_action::XDP_PASS);
    };

    let udphdr_slice =
        slice_mut_at::<{ UdpHeader::LEN }>(ctx, Ethernet2Header::LEN + Ipv4Header::MIN_LEN)?;
    let udphdr = parse_udp(udphdr_slice)?;

    let src_port = udphdr.source_port();
    let dst_port = udphdr.destination_port();
    let udp_payload_len = udphdr.length();
    let udp_checksum = udphdr.checksum();

    trace!(ctx, "New packet from {:i}:{}", src_addr, src_port);

    if dst_port == 3478 {
        let cdhdr = slice_mut_at::<{ CHANNEL_DATA_HEADER_LEN }>(
            ctx,
            Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN,
        )?;

        if !(64..=79).contains(&cdhdr[0]) {
            return Ok(xdp_action::XDP_PASS);
        }

        let channel_number = u16::from_be_bytes([cdhdr[0], cdhdr[1]]);

        // Untrusted because we read it from the packet.
        let untrusted_channel_data_length = u16::from_be_bytes([cdhdr[2], cdhdr[3]]);

        let channel_data_length = remaining_bytes(
            ctx,
            Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN + CHANNEL_DATA_HEADER_LEN,
        )?;

        // We received less (or more) data than the header said we would.
        if channel_data_length != usize::from(untrusted_channel_data_length) {
            return Ok(xdp_action::XDP_DROP);
        }

        let client_and_channel = ClientAndChannel::new(src_addr, src_port, channel_number);

        let binding = unsafe { CHANNELS_TO_UDP.get(&client_and_channel) };
        let Some(port_and_peer) = binding else {
            debug!(
                ctx,
                "No channel binding from {:x}:{:x} for channel {:x}",
                src_addr,
                src_port,
                channel_number,
            );

            return Ok(xdp_action::XDP_PASS);
        };

        {
            let mut ipv4hdr_mut = parse_ipv4_mut(ipv4hdr_slice)?;

            let new_src_addr = dst_addr; // The IP we received the packet on will be the new source IP.
            let new_dst_addr = port_and_peer.dest_ip();
            let new_tot_len = tot_len - 4;

            ipv4hdr_mut.set_source(new_src_addr.to_be_bytes());
            ipv4hdr_mut.set_destination(new_dst_addr.to_be_bytes());
            ipv4hdr_mut.set_total_length(new_tot_len.to_be_bytes());

            let new_ipv4_checksum = recompute_checksum(
                [
                    fold_u32_into_u16(src_addr),
                    fold_u32_into_u16(dst_addr),
                    tot_len,
                ],
                [
                    fold_u32_into_u16(new_src_addr),
                    fold_u32_into_u16(new_dst_addr),
                    new_tot_len,
                ],
                ipv4_checksum,
            );

            ipv4hdr_mut.set_checksum(new_ipv4_checksum);

            trace!(
                ctx,
                "Updating IP checksum from {:x} to {:x}",
                ipv4_checksum,
                new_ipv4_checksum
            );

            let mut udphdr_mut = parse_udp_mut(udphdr_slice)?;

            let new_src_port = port_and_peer.allocation_port();
            let new_dst_port = port_and_peer.dest_port();
            let new_udp_payload_len = udp_payload_len - 4;

            udphdr_mut.set_source_port(new_src_port);
            udphdr_mut.set_destination_port(new_dst_port);
            udphdr_mut.set_length(new_udp_payload_len);

            let new_udp_checksum = recompute_checksum(
                [
                    fold_u32_into_u16(src_addr),
                    fold_u32_into_u16(dst_addr),
                    // Yes the payload length needs to be in here twice because it is also used twice in the checksum calculation.
                    // Thus, any difference between the lengths must be accounted for in the checksum twice as well.
                    udp_payload_len,
                    udp_payload_len,
                    src_port,
                    dst_port,
                    channel_number,
                    untrusted_channel_data_length,
                ],
                [
                    fold_u32_into_u16(new_src_addr),
                    fold_u32_into_u16(new_dst_addr),
                    new_udp_payload_len,
                    new_udp_payload_len,
                    new_src_port,
                    new_dst_port,
                ],
                udp_checksum,
            );

            udphdr_mut.set_checksum(new_udp_checksum);

            trace!(
                ctx,
                "Updating UDP checksum from {:x} to {:x}",
                udp_checksum,
                new_udp_checksum
            );
        }

        remove_channel_data_header_ipv4(ctx);

        info!(
            ctx,
            "Redirecting message from {:i}:{} on channel {} to {:i}:{} on port {}",
            src_addr,
            src_port,
            channel_number,
            port_and_peer.dest_ip(),
            port_and_peer.dest_port(),
            port_and_peer.allocation_port()
        );

        Ok(xdp_action::XDP_TX)
    } else {
        try_handle_peer(ctx)
    }
}

fn remove_channel_data_header_ipv4(ctx: &XdpContext) {
    move_headers::<{ CHANNEL_DATA_HEADER_LEN as i32 }, { Ipv4Header::MIN_LEN }>(ctx)
}

fn add_channel_data_header_ipv4(ctx: &XdpContext) {
    move_headers::<{ -(CHANNEL_DATA_HEADER_LEN as i32) }, { Ipv4Header::MIN_LEN }>(ctx)
}

fn move_headers<const DELTA: i32, const IP_HEADER_LEN: usize>(ctx: &XdpContext) {
    // Scratch space for our headers.
    // IPv6 headers are always 40 bytes long.
    // IPv4 headers are between 20 and 60 bytes long.
    // We restrict the eBPF program to only handle 20 byte long IPv4 headers.
    // Therefore, we only need to reserver space for IPv6 headers.
    //
    // Ideally, we would just use the const-generic argument here but that is not yet supported ...
    let mut headers = [0u8; Ethernet2Header::LEN + Ipv6Header::LEN + UdpHeader::LEN];

    // Copy headers into buffer.
    unsafe {
        bpf_xdp_load_bytes(
            ctx.ctx,
            0,
            headers.as_mut_ptr() as *mut c_void,
            (Ethernet2Header::LEN + IP_HEADER_LEN + UdpHeader::LEN) as u32,
        );
    }

    // Move the head for the packet by `DELTA`.
    unsafe { bpf_xdp_adjust_head(ctx.ctx, DELTA) };

    // Copy the headers back (because we )
    unsafe {
        bpf_xdp_store_bytes(
            ctx.ctx,
            0,
            headers.as_mut_ptr() as *mut c_void,
            (Ethernet2Header::LEN + IP_HEADER_LEN + UdpHeader::LEN) as u32,
        )
    };
}

/// Recomputes an Internet checksum based on a list of removed and added fields to the packet.
///
/// This function expects the checksum to be provided `as-is` from the packet, i.e. in the "one's complement" format.
/// The return value is also in the "one's complement" format and can thus directly be written back to the packet.
///
/// # Example
///
/// If you change the destination port of a UDP packet, you would put the old destination port in `old_values` and the new destination port in `new_values`.
/// If you change the IP addresses (or anything else that is bigger than a u16), you first need to convert the value into a u16 using [`fold_u32_into_u16`].
fn recompute_checksum<const N1: usize, const N2: usize>(
    old_values: [u16; N1],
    new_values: [u16; N2],
    checksum: u16,
) -> u16 {
    let internal = !checksum; // Checksums are stored in the "one's complement" format, we need to unpack it first in order to perform math on it.

    let old_values = ones_complement_sum(old_values);
    let new_values = ones_complement_sum(new_values);

    // In one's complement arithmetic, we subtract the old values from the checksum by adding their one's complement.
    let minus_old_values = !old_values;

    let internal = ones_complement_sum([internal, minus_old_values, new_values]);

    !internal // "Repack" the checksum into the one's complement format.
}

fn ones_complement_sum<const N: usize>(values: [u16; N]) -> u16 {
    values.into_iter().fold(0u16, |acc, val| {
        // In one's complement arithmetic, addition requires adding a carry bit in case of overflow.
        let (acc, carry) = acc.overflowing_add(val);

        acc + (carry as u16)
    })
}

#[inline(always)]
fn fold_u32_into_u16(mut csum: u32) -> u16 {
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);

    csum as u16
}

#[inline(always)]
fn parse_udp(slice: &mut [u8]) -> Result<UdpHeaderSlice<'_>, Error> {
    UdpHeaderSlice::from_slice(slice).map_err(|_| Error::UdpHeader)
}

#[inline(always)]
fn parse_udp_mut(slice: &mut [u8]) -> Result<UdpHeaderSliceMut<'_>, Error> {
    UdpHeaderSliceMut::from_slice(slice).map_err(|_| Error::UdpHeader)
}

#[inline(always)]
fn parse_ipv4(slice: &mut [u8]) -> Result<Ipv4HeaderSlice<'_>, Error> {
    Ipv4HeaderSlice::from_slice(slice).map_err(|_| Error::Ipv4Header)
}

#[inline(always)]
fn parse_ipv4_mut(slice: &mut [u8]) -> Result<Ipv4HeaderSliceMut<'_>, Error> {
    Ipv4HeaderSliceMut::from_slice(slice).map_err(|_| Error::Ipv4Header)
}

#[inline(always)]
fn parse_eth(slice: &mut [u8]) -> Result<Ethernet2HeaderSlice<'_>, Error> {
    Ethernet2HeaderSlice::from_slice(slice).map_err(|_| Error::Ethernet2Header)
}

#[inline(always)]
fn try_handle_peer(_: &XdpContext) -> Result<u32, Error> {
    Err(Error::NotImplemented)
}

#[inline(always)]
fn slice_mut_at<const LEN: usize>(ctx: &XdpContext, offset: usize) -> Result<&mut [u8], Error> {
    let start = ctx.data();
    let end = ctx.data_end();

    if start + offset + LEN > end {
        return Err(Error::PacketTooShort);
    }

    Ok(unsafe { core::slice::from_raw_parts_mut((start + offset) as *mut u8, LEN) })
}

#[inline(always)]
fn remaining_bytes(ctx: &XdpContext, offset: usize) -> Result<usize, Error> {
    let start = ctx.data() + offset;
    let end = ctx.data_end();

    if start > end {
        return Err(Error::PacketTooShort);
    }

    let len = end - start;

    Ok(len)
}

#[cfg(test)]
mod tests {
    use core::net::Ipv4Addr;

    use super::*;

    #[test]
    fn recompute_udp_checksum() {
        let old_src_ip = Ipv4Addr::new(172, 28, 0, 100);
        let old_dst_ip = Ipv4Addr::new(172, 28, 0, 101);
        let old_src_port = 45088;
        let old_dst_port = 3478;
        let old_udp_payload = hex_literal::hex!("400100400101002c2112a44293d108418ca2a8fdf7e8930e002000080001b6c58d0ea42b00080014019672bb752bf292ecf95b498b8b4797eacef51d80280004a057ff1e");
        let channel_number = 0x4001;
        let channel_data_len = 0x0040;

        let incoming_ip_packet = ip_packet::make::udp_packet(
            old_src_ip,
            old_dst_ip,
            old_src_port,
            old_dst_port,
            old_udp_payload.to_vec(),
        )
        .unwrap();
        let incoming_checksum = incoming_ip_packet.as_udp().unwrap().checksum();

        let new_src_ip = Ipv4Addr::new(172, 28, 0, 101);
        let new_dst_ip = Ipv4Addr::new(172, 28, 0, 105);
        let new_src_port = 4324;
        let new_dst_port = 59385;
        let new_udp_payload = hex_literal::hex!("0101002c2112a44293d108418ca2a8fdf7e8930e002000080001b6c58d0ea42b00080014019672bb752bf292ecf95b498b8b4797eacef51d80280004a057ff1e");

        let outgoing_ip_packet = ip_packet::make::udp_packet(
            new_src_ip,
            new_dst_ip,
            new_src_port,
            new_dst_port,
            new_udp_payload.to_vec(),
        )
        .unwrap();
        let outgoing_checksum = outgoing_ip_packet.as_udp().unwrap().checksum();

        let computed_checksum = recompute_checksum(
            [
                fold_u32_into_u16(old_src_ip.to_bits()),
                fold_u32_into_u16(old_dst_ip.to_bits()),
                old_src_port,
                old_dst_port,
                old_udp_payload.len() as u16,
                old_udp_payload.len() as u16,
                channel_number,
                channel_data_len,
            ],
            [
                fold_u32_into_u16(new_src_ip.to_bits()),
                fold_u32_into_u16(new_dst_ip.to_bits()),
                new_src_port,
                new_dst_port,
                new_udp_payload.len() as u16,
                new_udp_payload.len() as u16,
            ],
            incoming_checksum,
        );

        assert_eq!(computed_checksum, outgoing_checksum)
    }
}
