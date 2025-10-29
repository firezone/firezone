use aya_ebpf::programs::XdpContext;
use ebpf_shared::ClientAndChannelV6;
use network_types::{eth::EthHdr, ip::Ipv6Hdr, udp::UdpHdr};

use crate::try_handle_turn::{
    Error, adjust_head, channel_data::CdHdr, checksum::ChecksumUpdate, ref_mut_at,
};

#[inline(always)]
pub fn to_ipv6_channel(
    ctx: &XdpContext,
    client_and_channel: &ClientAndChannelV6,
) -> Result<(), Error> {
    // Expand by 4 bytes for channel data header
    const NET_EXPANSION: i32 = -(CdHdr::LEN as i32);

    adjust_head(ctx, NET_EXPANSION)?;

    // Now read the old packet data from its NEW location (shifted by 4 bytes)
    let old_data_offset = CdHdr::LEN;

    let (old_eth_src, old_eth_dst, old_eth_type) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, old_data_offset)? };
        (old_eth.src_addr, old_eth.dst_addr, old_eth.ether_type)
    };

    let (
        old_ipv6_src,
        old_ipv6_dst,
        old_ipv6_len,
        old_ipv6_dscp,
        old_ipv6_ecn,
        old_ipv6_flow_label,
        old_ipv6_hop_limit,
        old_ipv6_next_hdr,
    ) = {
        // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
        let old_ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
        (
            old_ipv6.src_addr(),
            old_ipv6.dst_addr(),
            old_ipv6.payload_len(),
            old_ipv6.dscp(),
            old_ipv6.ecn(),
            old_ipv6.flow_label(),
            old_ipv6.hop_limit,
            old_ipv6.next_hdr,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp =
            unsafe { ref_mut_at::<UdpHdr>(ctx, old_data_offset + EthHdr::LEN + Ipv6Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.src_port(),
            old_udp.dst_port(),
            old_udp.checksum(),
        )
    };

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
    eth.src_addr = old_eth_dst; // Swap source and destination
    eth.dst_addr = old_eth_src;
    eth.ether_type = old_eth_type;

    //
    // 2. IPv6 header
    //

    let new_ipv6_src = old_ipv6_dst;
    let new_ipv6_dst = client_and_channel.client_ip();
    let new_ipv6_len = old_ipv6_len + CdHdr::LEN as u16;

    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    // Set fields explicitly to avoid reading potentially corrupted memory
    ipv6.set_vcf(6, old_ipv6_dscp, old_ipv6_ecn, old_ipv6_flow_label);
    ipv6.set_payload_len(new_ipv6_len);
    ipv6.next_hdr = old_ipv6_next_hdr;
    ipv6.hop_limit = old_ipv6_hop_limit;
    ipv6.set_src_addr(new_ipv6_src);
    ipv6.set_dst_addr(new_ipv6_dst);

    //
    // 3. UDP header
    //

    let channel_number = client_and_channel.channel();
    let channel_data_length = old_udp_len - UdpHdr::LEN as u16;
    let new_udp_len = old_udp_len + CdHdr::LEN as u16;
    let new_udp_src = 3478_u16;
    let new_udp_dst = client_and_channel.client_port();

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_src_port(new_udp_src);
    udp.set_dst_port(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_checksum(
        ChecksumUpdate::new(old_udp_check)
            .remove_u128(u128::from_be_bytes(old_ipv6_src.octets()))
            .add_u128(u128::from_be_bytes(new_ipv6_dst.octets()))
            .remove_u16(old_udp_src)
            .add_u16(new_udp_src)
            .remove_u16(old_udp_dst)
            .add_u16(new_udp_dst)
            .remove_u16(old_udp_len)
            .add_u16(new_udp_len)
            .remove_u16(old_udp_len)
            .add_u16(new_udp_len)
            .add_u16(channel_number)
            .add_u16(channel_data_length)
            .into_udp_checksum(),
    );

    //
    // 4. Channel data header
    //

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };
    cd.number = channel_number.to_be_bytes();
    cd.length = channel_data_length.to_be_bytes();

    Ok(())
}
