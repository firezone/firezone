use aya_ebpf::programs::XdpContext;
use ebpf_shared::ClientAndChannelV4;
use network_types::{eth::EthHdr, ip::Ipv4Hdr, udp::UdpHdr};

use crate::try_handle_turn::{Error, channel_data::CdHdr, checksum::ChecksumUpdate, ref_mut_at};

#[inline(always)]
pub fn to_ipv4_channel(
    ctx: &XdpContext,
    client_and_channel: &ClientAndChannelV4,
) -> Result<(), Error> {
    let (old_eth_src, old_eth_dst, old_eth_type) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
        (old_eth.src_addr, old_eth.dst_addr, old_eth.ether_type)
    };

    let (old_ipv4_src, old_ipv4_dst, _, old_ipv4_check, ..) = {
        // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
        let old_ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };
        (
            old_ipv4.src_addr(),
            old_ipv4.dst_addr(),
            old_ipv4.tot_len(),
            old_ipv4.checksum(),
            old_ipv4.tos,
            old_ipv4.id(),
            old_ipv4.frag_flags(),
            old_ipv4.frag_offset(),
            old_ipv4.ttl,
            old_ipv4.proto,
        )
    };

    let (_, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.src_port(),
            old_udp.dst_port(),
            old_udp.checksum(),
        )
    };

    let (old_channel_number, _) = {
        let old_cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN)? };

        (old_cd.number(), old_cd.length())
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

    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)? };
    ipv4.set_src_addr(new_ipv4_src); // Swap source and destination
    ipv4.set_dst_addr(new_ipv4_dst); // Destination is the client IP
    ipv4.set_checksum(
        ChecksumUpdate::new(old_ipv4_check)
            .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
            .add_u32(u32::from_be_bytes(new_ipv4_dst.octets()))
            .into_ip_checksum(),
    );

    //
    // 3. UDP header
    //

    let new_udp_src = 3478_u16;
    let new_udp_dst = client_and_channel.client_port();
    let channel_number = client_and_channel.channel();

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_src_port(new_udp_src);
    udp.set_dst_port(new_udp_dst);

    // Incrementally update UDP checksum

    if old_udp_check == 0 {
        // No checksum is valid for UDP IPv4 - we didn't write it, but maybe a middlebox did
        udp.set_checksum(0);
    } else {
        udp.set_checksum(
            ChecksumUpdate::new(old_udp_check)
                .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
                .add_u32(u32::from_be_bytes(new_ipv4_dst.octets()))
                .remove_u16(old_udp_src)
                .add_u16(new_udp_src)
                .remove_u16(old_udp_dst)
                .add_u16(new_udp_dst)
                .remove_u16(old_channel_number)
                .add_u16(channel_number)
                .into_udp_checksum(),
        );
    }

    //
    // 4. Channel data header
    //

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN)? };
    cd.number = channel_number.to_be_bytes();

    Ok(())
}
