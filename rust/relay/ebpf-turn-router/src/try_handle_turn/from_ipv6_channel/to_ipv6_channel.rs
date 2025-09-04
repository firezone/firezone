use aya_ebpf::programs::XdpContext;
use ebpf_shared::ClientAndChannelV6;
use network_types::{eth::EthHdr, ip::Ipv6Hdr, udp::UdpHdr};

use crate::try_handle_turn::{Error, channel_data::CdHdr, checksum::ChecksumUpdate, ref_mut_at};

#[inline(always)]
pub fn to_ipv6_channel(
    ctx: &XdpContext,
    client_and_channel: &ClientAndChannelV6,
) -> Result<(), Error> {
    let (old_eth_src, old_eth_dst, old_eth_type) = {
        // SAFETY: The offset must point to the start of a valid `EthHdr`.
        let old_eth = unsafe { ref_mut_at::<EthHdr>(ctx, 0)? };
        (old_eth.src_addr, old_eth.dst_addr, old_eth.ether_type)
    };

    let (old_ipv6_src, old_ipv6_dst, ..) = {
        // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
        let old_ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
        (
            old_ipv6.src_addr(),
            old_ipv6.dst_addr(),
            old_ipv6.payload_len(),
            old_ipv6.priority(),
            old_ipv6.flow_label,
            old_ipv6.hop_limit,
            old_ipv6.next_hdr,
        )
    };

    let (_, old_udp_src, old_udp_dst, old_udp_check) = {
        // SAFETY: The offset must point to the start of a valid `UdpHdr`.
        let old_udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
        (
            old_udp.len(),
            old_udp.source(),
            old_udp.dest(),
            old_udp.check(),
        )
    };

    let (old_channel_number, _) = {
        let old_cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };

        (old_cd.number(), old_cd.length())
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

    // SAFETY: The offset must point to the start of a valid `Ipv6Hdr`.
    let ipv6 = unsafe { ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)? };
    ipv6.set_src_addr(new_ipv6_src);
    ipv6.set_dst_addr(new_ipv6_dst);

    //
    // 3. UDP header
    //

    let channel_number = client_and_channel.channel();
    let new_udp_src = 3478_u16;
    let new_udp_dst = client_and_channel.client_port();

    // SAFETY: The offset must point to the start of a valid `UdpHdr`.
    let udp = unsafe { ref_mut_at::<UdpHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN)? };
    udp.set_source(new_udp_src);
    udp.set_dest(new_udp_dst);

    // Incrementally update UDP checksum

    udp.set_check(
        ChecksumUpdate::new(old_udp_check)
            .remove_u128(u128::from_be_bytes(old_ipv6_src.octets()))
            .add_u128(u128::from_be_bytes(new_ipv6_dst.octets()))
            .remove_u16(old_udp_src)
            .add_u16(new_udp_src)
            .remove_u16(old_udp_dst)
            .add_u16(new_udp_dst)
            .remove_u16(old_channel_number)
            .add_u16(channel_number)
            .into_udp_checksum(),
    );

    //
    // 4. Channel data header
    //

    // SAFETY: The offset must point to the start of a valid `CdHdr`.
    let cd = unsafe { ref_mut_at::<CdHdr>(ctx, EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN)? };
    cd.number = channel_number.to_be_bytes();

    Ok(())
}
