use aya_ebpf::programs::XdpContext;
use ebpf_shared::PortAndPeerV4;
use network_types::{eth::EthHdr, ip::Ipv4Hdr, udp::UdpHdr};

use crate::try_handle_turn::{
    Error, adjust_head, channel_data::CdHdr, checksum::ChecksumUpdate, ref_mut_at,
};

#[inline(always)]
pub fn to_ipv4_udp(ctx: &XdpContext, port_and_peer: &PortAndPeerV4) -> Result<(), Error> {
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
        old_ipv4_frag_flags,
        old_ipv4_frag_offset,
        old_ipv4_ttl,
        old_ipv4_proto,
    ) = {
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

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.src_port(),
            old_udp.dst_port(),
            old_udp.checksum(),
        )
    };

    let (channel_number, channel_data_length) = {
        // SAFETY: The offset must point to the start of a valid `CdHdr`.
        let old_cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN)? };
        (old_cd.number(), old_cd.length())
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

    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, NET_SHRINK as usize + EthHdr::LEN)? };
    ipv4.set_vihl(4, 20); // IPv4
    ipv4.tos = old_ipv4_tos; // Preserve TOS/DSCP
    ipv4.set_tot_len(new_ipv4_len);
    ipv4.set_id(old_ipv4_id); // Preserve ID
    ipv4.set_frags(old_ipv4_frag_flags, old_ipv4_frag_offset); // Preserve fragment flags
    ipv4.ttl = old_ipv4_ttl; // Preserve TTL exactly
    ipv4.proto = old_ipv4_proto; // Protocol is UDP
    ipv4.set_src_addr(new_ipv4_src);
    ipv4.set_dst_addr(new_ipv4_dst);
    ipv4.set_checksum(
        ChecksumUpdate::new(old_ipv4_check)
            .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
            .add_u32(u32::from_be_bytes(new_ipv4_dst.octets()))
            .remove_u16(old_ipv4_len)
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
    udp.set_src_port(new_udp_src);
    udp.set_dst_port(new_udp_dst);
    udp.set_len(new_udp_len);

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
                .remove_u16(old_udp_len)
                .add_u16(new_udp_len)
                .remove_u16(old_udp_len)
                .add_u16(new_udp_len)
                .remove_u16(channel_number)
                .remove_u16(channel_data_length)
                .into_udp_checksum(),
        );
    }

    adjust_head(ctx, NET_SHRINK)?;

    Ok(())
}
