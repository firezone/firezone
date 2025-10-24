use aya_ebpf::programs::XdpContext;
use ebpf_shared::ClientAndChannelV4;
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};

use crate::try_handle_turn::{
    Error, adjust_head,
    channel_data::CdHdr,
    checksum::{self, ChecksumUpdate},
    config, ref_mut_at,
};

#[inline(always)]
pub fn to_ipv4_channel(
    ctx: &XdpContext,
    client_and_channel: &ClientAndChannelV4,
) -> Result<(), Error> {
    // 40 - 20 - 4 = 16 bytes shrink
    const NET_SHRINK: i32 = Ipv6Hdr::LEN as i32 - Ipv4Hdr::LEN as i32 - CdHdr::LEN as i32;

    let (old_eth_src, old_eth_dst) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
        (old_eth.src_addr, old_eth.dst_addr)
    };

    let (
        old_ipv6_src,
        old_ipv6_dst,
        old_ipv6_dscp,
        old_ipv6_ecn,
        old_ipv6_hop_limit,
        old_ipv6_next_hdr,
    ) = {
        // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
        let old_ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
        (
            old_ipv6.src_addr(),
            old_ipv6.dst_addr(),
            old_ipv6.dscp(),
            old_ipv6.ecn(),
            old_ipv6.hop_limit,
            old_ipv6.next_hdr,
        )
    };

    let (old_udp_len, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
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
    let eth = unsafe { ref_mut_at::<EthHdr>(ctx, NET_SHRINK as usize)? };
    eth.src_addr = old_eth_dst; // Swap source and destination
    eth.dst_addr = old_eth_src;
    eth.ether_type = EtherType::Ipv4.into(); // Change to IPv4

    //
    // 2. IPv6 -> IPv4 header
    //

    let new_ipv4_src = config::interface_ipv4_address()?;
    let new_ipv4_dst = client_and_channel.client_ip();
    let new_udp_len = old_udp_len + CdHdr::LEN as u16;
    let new_ipv4_len = Ipv4Hdr::LEN as u16 + new_udp_len;

    // SAFETY: The offset must point to the start of a valid `Ipv4Hdr`.
    let ipv4 = unsafe { ref_mut_at::<Ipv4Hdr>(ctx, NET_SHRINK as usize + EthHdr::LEN)? };
    ipv4.set_vihl(4, 20);
    ipv4.set_tos(old_ipv6_dscp, old_ipv6_ecn); // Copy TOS from IPv6
    ipv4.set_tot_len(new_ipv4_len);
    ipv4.set_id(0); // Default ID
    ipv4.set_frags(0b010, 0); // Don't fragment
    ipv4.ttl = old_ipv6_hop_limit; // Preserve hop limit
    ipv4.proto = old_ipv6_next_hdr; // Preserve protocol
    ipv4.set_src_addr(new_ipv4_src);
    ipv4.set_dst_addr(new_ipv4_dst);

    // Calculate fresh checksum
    let check = checksum::new_ipv4(ipv4);
    ipv4.set_checksum(check);

    //
    // 3. UDP header
    //

    let new_udp_src = 3478_u16; // Fixed source port for TURN
    let new_udp_dst = client_and_channel.client_port();
    let channel_number = client_and_channel.channel();
    let channel_data_length = old_udp_len - UdpHdr::LEN as u16;

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp =
        unsafe { ref_mut_at::<UdpHdr>(ctx, NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN)? };
    udp.set_src_port(new_udp_src);
    udp.set_dst_port(new_udp_dst);
    udp.set_len(new_udp_len);

    // Incrementally update UDP checksum

    udp.set_checksum(
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
            .add_u16(channel_number)
            .add_u16(channel_data_length)
            .into_udp_checksum(),
    );

    //
    // 4. Channel data header
    //

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
    let cd = unsafe {
        ref_mut_at::<CdHdr>(
            ctx,
            NET_SHRINK as usize + EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN,
        )?
    };
    cd.number = channel_number.to_be_bytes();
    cd.length = channel_data_length.to_be_bytes();

    adjust_head(ctx, NET_SHRINK)?;

    Ok(())
}
