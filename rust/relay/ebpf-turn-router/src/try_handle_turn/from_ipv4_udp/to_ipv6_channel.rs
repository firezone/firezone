use aya_ebpf::programs::XdpContext;
use ebpf_shared::ClientAndChannelV6;
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};

use crate::try_handle_turn::{
    Error, adjust_head, channel_data::CdHdr, checksum::ChecksumUpdate, interface, ref_mut_at,
};

#[inline(always)]
pub fn to_ipv6_channel(
    ctx: &XdpContext,
    client_and_channel: &ClientAndChannelV6,
) -> Result<(), Error> {
    // Expand the packet by 24 bytes for IPv6 header and channel data header
    const NET_EXPANSION: i32 = -(Ipv6Hdr::LEN as i32 - Ipv4Hdr::LEN as i32 + CdHdr::LEN as i32);

    adjust_head(ctx, NET_EXPANSION)?;

    // Now read the old packet data from its NEW location (shifted by 24 bytes)
    let old_data_offset = -NET_EXPANSION as usize;

    let (old_eth_src, old_eth_dst) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, old_data_offset)? };
        (old_eth.src_addr, old_eth.dst_addr)
    };

    let (old_ipv4_src, old_ipv4_dst, old_ipv4_len, old_ipv4_tos, old_ipv4_ttl, old_ipv4_proto) = {
        // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
        let old_ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, old_data_offset + EthHdr::LEN)? };
        (
            old_ipv4.src_addr(),
            old_ipv4.dst_addr(),
            old_ipv4.total_len(),
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

    //
    // 1. Ethernet header
    //

    // SAFETY: The offset must point to the start of a valid `EthHdr`.
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
    eth.dst_addr = old_eth_src; // Swap source and destination
    eth.src_addr = old_eth_dst;
    eth.ether_type = EtherType::Ipv6; // Change to IPv6

    //
    // 2. IPv4 -> IPv6 header
    //

    let new_ipv6_src = interface::ipv6_address()?;
    let new_ipv6_dst = client_and_channel.client_ip();
    let new_ipv6_len = old_ipv4_len - Ipv4Hdr::LEN as u16 + CdHdr::LEN as u16;

    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    ipv6.set_version(6);
    ipv6.set_priority(old_ipv4_tos);
    ipv6.flow_label = [0, 0, 0]; // Default flow label
    ipv6.set_payload_len(new_ipv6_len);
    ipv6.next_hdr = old_ipv4_proto;
    ipv6.hop_limit = old_ipv4_ttl;
    ipv6.set_src_addr(new_ipv6_src);
    ipv6.set_dst_addr(new_ipv6_dst);

    //
    // 3. UDP header
    //

    let new_udp_src = 3478_u16;
    let new_udp_dst = client_and_channel.client_port();
    let new_udp_len = old_udp_len + CdHdr::LEN as u16;

    let channel_number = client_and_channel.channel();
    let channel_data_length = old_udp_len - UdpHdr::LEN as u16;

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
