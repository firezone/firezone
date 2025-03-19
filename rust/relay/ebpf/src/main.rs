#![no_std]
#![no_main]

use crate::error::Error;
use aya_ebpf::{
    bindings::xdp_action,
    macros::{map, xdp},
    maps::HashMap,
    programs::XdpContext,
};
use aya_log_ebpf::*;
use etherparse::{
    checksum, EtherType, Ethernet2Header, Ethernet2HeaderSlice, IpNumber, Ipv4HeaderSlice,
    UdpHeader, UdpHeaderSlice,
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

            xdp_action::XDP_ABORTED
        }
    }
}

const CHANNEL_DATA_HEADER_LEN: usize = 4;

fn try_handle_turn(ctx: &XdpContext) -> Result<u32, Error> {
    // SAFETY:
    // - single u8 is always aligned
    // - we checked the length
    // - data within `XdpContext` is always continguous memory
    let packet = unsafe {
        core::slice::from_raw_parts_mut(ctx.data() as *mut u8, ctx.data_end() - ctx.data())
    };

    let (ethhdr_slice, ethernet_payload) = packet
        .split_at_mut_checked(Ethernet2Header::LEN)
        .ok_or(Error::SplitMutFailed)?;
    let ethhdr = parse_eth(ethhdr_slice)?;

    match ethhdr.ether_type() {
        EtherType::IPV4 => {}
        _ => return Ok(xdp_action::XDP_PASS),
    }

    let ipv4hdr_length = (parse_ipv4(ethernet_payload)?.ihl() as usize) * 4;
    let (ipv4hdr_slice, ipv4_payload) = ethernet_payload
        .split_at_mut_checked(ipv4hdr_length)
        .ok_or(Error::SplitMutFailed)?;
    let ipv4hdr = parse_ipv4(ipv4hdr_slice)?;

    let source_addr = u32::from_be_bytes(ipv4hdr.source());
    let tot_len = ipv4hdr.total_len();

    let IpNumber::UDP = ipv4hdr.protocol() else {
        return Ok(xdp_action::XDP_PASS);
    };

    let (udphdr_slice, udp_payload) = ipv4_payload
        .split_at_mut_checked(UdpHeader::LEN)
        .ok_or(Error::SplitMutFailed)?;
    let udp_payload_ptr = udp_payload.as_mut_ptr();
    let udphdr = parse_udp(udphdr_slice)?;

    let source_port = udphdr.source_port();
    let dest_port = udphdr.destination_port();
    let udp_payload_len = udphdr.length();

    trace!(ctx, "New packet from {:i}:{}", source_addr, source_port);

    if dest_port == 3478 {
        // Handle channel data messages

        let (cdhdr, channel_data_payload) = udp_payload
            .split_at_mut_checked(CHANNEL_DATA_HEADER_LEN)
            .ok_or(Error::SplitMutFailed)?;
        let channel_data_payload_ptr = channel_data_payload.as_mut_ptr();

        if !(64..=79).contains(&cdhdr[0]) {
            return Ok(xdp_action::XDP_PASS);
        }

        let channel_number = u16::from_be_bytes([cdhdr[0], cdhdr[1]]);
        let channel_data_length = usize::from(u16::from_be_bytes([cdhdr[2], cdhdr[3]]));

        if channel_data_length > channel_data_payload.len() {
            warn!(ctx, "Length of channel data message out of bounds");

            return Ok(xdp_action::XDP_PASS);
        }

        let client_and_channel = ClientAndChannel::new(source_addr, source_port, channel_number);

        let binding = unsafe { CHANNELS_TO_UDP.get(&client_and_channel) };
        let Some(port_and_peer) = binding else {
            debug!(
                ctx,
                "No channel binding from {:x}:{:x} for channel {:x}",
                source_addr,
                source_port,
                channel_number,
            );

            return Ok(xdp_action::XDP_PASS);
        };

        let ipv4_dst = ipv4hdr.destination();

        {
            let mut ipv4hdr_mut = parse_ipv4_mut(ipv4hdr_slice)?;

            ipv4hdr_mut.set_source(ipv4_dst); // The IP we received the packet on will be the new source IP.
            ipv4hdr_mut.set_destination(port_and_peer.dest_ip().to_be_bytes());
            ipv4hdr_mut.set_total_length((tot_len - 4).to_be_bytes());
        }

        {
            let mut udphdr_mut = parse_udp_mut(udphdr_slice)?;

            udphdr_mut.set_source_port(port_and_peer.allocation_port());
            udphdr_mut.set_destination_port(port_and_peer.dest_port());
            udphdr_mut.set_length(udp_payload_len - 4);
        }

        {
            let ipv4_header = parse_ipv4(ipv4hdr_slice)?;

            let udp_checksum = parse_udp(udphdr_slice)?
                .to_header()
                .calc_checksum_ipv4_raw(
                    ipv4_header.source(),
                    ipv4_header.destination(),
                    channel_data_payload,
                )
                .map_err(|_| Error::UdpChecksum)?;
            let ipv4_checksum = calc_ipv4_checksum(&ipv4_header);

            parse_udp_mut(udphdr_slice)?.set_checksum(udp_checksum);
            parse_ipv4_mut(ipv4hdr_slice)?.set_checksum(ipv4_checksum);
        }

        unsafe {
            aya_ebpf::memmove(
                udp_payload_ptr,
                channel_data_payload_ptr,
                channel_data_length,
            );
        }

        info!(
            ctx,
            "Redirecting message from {:i}:{} on channel {} to {:i}:{} on port {}",
            source_addr,
            source_port,
            channel_number,
            port_and_peer.dest_ip(),
            port_and_peer.dest_port(),
            port_and_peer.allocation_port()
        );

        Ok(xdp_action::XDP_REDIRECT)
    } else {
        try_handle_peer(ctx)
    }
}

fn calc_ipv4_checksum(ipv4_header: &Ipv4HeaderSlice) -> u16 {
    checksum::Sum16BitWords::new()
        .add_2bytes([
            (4 << 4) | ipv4_header.ihl(),
            (ipv4_header.dcp().value() << 2) | ipv4_header.ecn().value(),
        ])
        .add_2bytes(ipv4_header.total_len().to_be_bytes())
        .add_2bytes(ipv4_header.identification().to_be_bytes())
        .add_2bytes({
            let frag_off_be = ipv4_header.fragments_offset().value().to_be_bytes();
            let flags = {
                let mut result = 0;
                if ipv4_header.dont_fragment() {
                    result |= 64;
                }
                if ipv4_header.more_fragments() {
                    result |= 32;
                }
                result
            };
            [flags | (frag_off_be[0] & 0x1f), frag_off_be[1]]
        })
        .add_2bytes([ipv4_header.ttl(), ipv4_header.protocol().0])
        .add_4bytes(ipv4_header.source())
        .add_4bytes(ipv4_header.destination())
        .add_slice(ipv4_header.options())
        .ones_complement()
        .to_be()
}

fn parse_udp(slice: &mut [u8]) -> Result<UdpHeaderSlice<'_>, Error> {
    UdpHeaderSlice::from_slice(slice).map_err(|_| Error::UdpHeader)
}

fn parse_udp_mut(slice: &mut [u8]) -> Result<UdpHeaderSliceMut<'_>, Error> {
    UdpHeaderSliceMut::from_slice(slice).map_err(|_| Error::UdpHeader)
}

fn parse_ipv4(slice: &mut [u8]) -> Result<Ipv4HeaderSlice<'_>, Error> {
    Ipv4HeaderSlice::from_slice(slice).map_err(|_| Error::Ipv4Header)
}

fn parse_ipv4_mut(slice: &mut [u8]) -> Result<Ipv4HeaderSliceMut<'_>, Error> {
    Ipv4HeaderSliceMut::from_slice(slice).map_err(|_| Error::Ipv4Header)
}

fn parse_eth(slice: &mut [u8]) -> Result<Ethernet2HeaderSlice<'_>, Error> {
    Ethernet2HeaderSlice::from_slice(slice).map_err(|_| Error::Ethernet2Header)
}

fn try_handle_peer(_: &XdpContext) -> Result<u32, Error> {
    Err(Error::NotImplemented)
}
