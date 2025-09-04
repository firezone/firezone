use aya_ebpf::programs::XdpContext;
use ebpf_shared::PortAndPeerV4;
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};

use crate::try_handle_turn::{
    Error, adjust_head,
    channel_data::CdHdr,
    checksum::{self, ChecksumUpdate},
    interface, ref_mut_at,
};

#[inline(always)]
pub fn to_ipv4_udp(ctx: &XdpContext, port_and_peer: &PortAndPeerV4) -> Result<(), Error> {
    // Shrink by 24 bytes: 20 for the IP header diff and 4 for the removed channel data header
    const NET_SHRINK: i32 = Ipv6Hdr::LEN as i32 - Ipv4Hdr::LEN as i32 + CdHdr::LEN as i32;

    let (old_eth_src, old_eth_dst) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
        (old_eth.src_addr, old_eth.dst_addr)
    };

    let (old_ipv6_src, old_ipv6_dst, old_ipv6_priority, old_ipv6_hop_limit, old_ipv6_next_hdr) = {
        // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
        let old_ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
        (
            old_ipv6.src_addr(),
            old_ipv6.dst_addr(),
            old_ipv6.priority(),
            old_ipv6.hop_limit,
            old_ipv6.next_hdr,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    let (channel_number, channel_data_length) = {
        // SAFETY: The offset must point to the start of a valid `CdHdr`.
        let old_cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };
        (old_cd.number(), old_cd.length())
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, NET_SHRINK as usize)? };
    eth.src_addr = old_eth_dst; // Swap source and destination
    eth.dst_addr = old_eth_src;
    eth.ether_type = EtherType::Ipv4; // Change to IPv4

    //
    // 2. IPv6 -> IPv4 header
    //

    let new_ipv4_src = interface::ipv4_address()?;
    let new_ipv4_dst = port_and_peer.peer_ip();
    let new_ipv4_len = old_udp_len - CdHdr::LEN as u16 + Ipv4Hdr::LEN as u16;

    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, NET_SHRINK as usize + EthHdr::LEN)? };
    ipv4.set_version(4);
    ipv4.set_ihl(5); // No options
    ipv4.tos = old_ipv6_priority; // Copy TOS from IPv6
    ipv4.set_total_len(new_ipv4_len);
    ipv4.set_id(0); // Default ID
    ipv4.frag_off = 0x4000_u16.to_be_bytes(); // Don't fragment
    ipv4.ttl = old_ipv6_hop_limit; // Preserve TTL
    ipv4.proto = old_ipv6_next_hdr; // Copy protocol from IPv6
    ipv4.set_src_addr(new_ipv4_src);
    ipv4.set_dst_addr(new_ipv4_dst);

    // Calculate fresh checksum
    let check = checksum::new_ipv4(ipv4);
    ipv4.set_checksum(check);

    //
    // 3. UDP header
    //

    let new_udp_src = port_and_peer.allocation_port();
    let new_udp_dst = port_and_peer.peer_port();
    let new_udp_len = old_udp_len - CdHdr::LEN as u16;

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_check(
        ChecksumUpdate::new(old_udp_check)
            .remove_u128(u128::from_be_bytes(old_ipv6_src.octets()))
            .add_u32(u32::from_be_bytes(new_ipv4_src.octets()))
            .remove_u128(u128::from_be_bytes(old_ipv6_dst.octets()))
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

    adjust_head(ctx, NET_SHRINK)?;

    Ok(())
}
