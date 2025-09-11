use aya_ebpf::programs::XdpContext;
use ebpf_shared::PortAndPeerV6;
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};

use crate::try_handle_turn::{
    Error, adjust_head, channel_data::CdHdr, checksum::ChecksumUpdate, config, ref_mut_at,
};

#[inline(always)]
pub fn to_ipv6_udp(ctx: &XdpContext, port_and_peer: &PortAndPeerV6) -> Result<(), Error> {
    const NET_EXPANSION: i32 = Ipv4Hdr::LEN as i32 - Ipv6Hdr::LEN as i32 + CdHdr::LEN as i32;

    adjust_head(ctx, NET_EXPANSION)?;

    // Now read the old packet data from its NEW location
    let old_data_offset = (-NET_EXPANSION) as usize;

    let (old_src_mac, old_dst_mac) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, old_data_offset)? };
        (old_eth.src_addr, old_eth.dst_addr)
    };

    let (old_ipv4_src, old_ipv4_dst, old_ipv4_tos, old_ipv4_ttl, old_ipv4_proto) = {
        // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
        let old_ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
        (
            old_ipv4.src_addr(),
            old_ipv4.dst_addr(),
            old_ipv4.tos,
            old_ipv4.ttl,
            old_ipv4.proto,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp =
            unsafe { ref_mut_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    // Refuse to compute full UDP checksum.
    // We forged these packets, so something's wrong if this is zero.
    if old_udp_check == 0 {
        return Err(Error::UdpChecksumMissing);
    }

    let (channel_number, channel_data_length) = {
        // SAFETY: The offset must point to the start of a valid `CdHdr`.
        let old_cd = unsafe {
            ref_mut_at::<CdHdr>(
                ctx,
                old_data_offset + EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN,
            )?
        };
        (old_cd.number(), old_cd.length())
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
    eth.dst_addr = old_src_mac; // Swap MACs
    eth.src_addr = old_dst_mac;
    eth.ether_type = EtherType::Ipv6; // Change to IPv6

    //
    // 2. IPv6 header
    //

    let new_ipv6_src = config::interface_ipv6_address()?;
    let new_ipv6_dst = port_and_peer.peer_ip();
    let new_udp_len = old_udp_len - CdHdr::LEN as u16;

    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    ipv6.set_version(6); // IPv6
    ipv6.set_priority(old_ipv4_tos);
    ipv6.flow_label = [0, 0, 0];
    ipv6.set_payload_len(new_udp_len);
    ipv6.next_hdr = old_ipv4_proto;
    ipv6.hop_limit = old_ipv4_ttl;
    ipv6.set_src_addr(new_ipv6_src);
    ipv6.set_dst_addr(new_ipv6_dst);

    //
    // 3. UDP header
    //

    let new_udp_src = port_and_peer.allocation_port();
    let new_udp_dst = port_and_peer.peer_port();

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_check(
        ChecksumUpdate::new(old_udp_check)
            .remove_u32(u32::from_be_bytes(old_ipv4_src.octets()))
            .add_u128(u128::from_be_bytes(new_ipv6_src.octets()))
            .remove_u32(u32::from_be_bytes(old_ipv4_dst.octets()))
            .add_u128(u128::from_be_bytes(new_ipv6_dst.octets()))
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

    Ok(())
}
