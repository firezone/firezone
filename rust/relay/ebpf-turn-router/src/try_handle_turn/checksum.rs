//! Checksum helpers for the TURN router.
//!
//! Incremental checksum updates live in the shared [`incremental_inet_checksum`] crate;
//! this module re-exports them and adds the eBPF-specific helpers.

pub use incremental_inet_checksum::ChecksumUpdate;

use network_types::ip::Ipv4Hdr;

/// Calculate a fresh IPv4 header checksum
#[inline(always)]
pub fn new_ipv4(ipv4: &mut Ipv4Hdr) -> u16 {
    // Zero the checksum field before calculation
    ipv4.set_checksum(0);

    // Cast the IPv4 header to bytes and process as u16 words
    let header_bytes =
        unsafe { core::slice::from_raw_parts(ipv4 as *const _ as *const u8, Ipv4Hdr::LEN) };

    let mut sum = 0u32;
    let mut i = 0;
    while i < Ipv4Hdr::LEN {
        // Read two bytes as a u16 in network byte order
        let word = ((header_bytes[i] as u16) << 8) | (header_bytes[i + 1] as u16);
        sum += word as u32;
        i += 2;
    }

    // Fold carries
    while sum > 0xffff {
        sum = (sum & 0xffff) + (sum >> 16);
    }

    // One's complement
    !(sum as u16)
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
        let old_udp_payload = hex_literal::hex!(
            "400100400101002c2112a44293d108418ca2a8fdf7e8930e002000080001b6c58d0ea42b00080014019672bb752bf292ecf95b498b8b4797eacef51d80280004a057ff1e"
        );
        let channel_number = 0x4001;
        let channel_data_len = 0x0040;

        let incoming_ip_packet = ip_packet::make::udp_packet(
            old_src_ip,
            old_dst_ip,
            old_src_port,
            old_dst_port,
            &old_udp_payload,
        )
        .unwrap();
        let incoming_checksum = incoming_ip_packet.as_udp().unwrap().checksum();

        let new_src_ip = Ipv4Addr::new(172, 28, 0, 101);
        let new_dst_ip = Ipv4Addr::new(172, 28, 0, 105);
        let new_src_port = 4324;
        let new_dst_port = 59385;
        let new_udp_payload = hex_literal::hex!(
            "0101002c2112a44293d108418ca2a8fdf7e8930e002000080001b6c58d0ea42b00080014019672bb752bf292ecf95b498b8b4797eacef51d80280004a057ff1e"
        );

        let outgoing_ip_packet = ip_packet::make::udp_packet(
            new_src_ip,
            new_dst_ip,
            new_src_port,
            new_dst_port,
            &new_udp_payload,
        )
        .unwrap();
        let outgoing_checksum = outgoing_ip_packet.as_udp().unwrap().checksum();

        let computed_checksum = ChecksumUpdate::new(incoming_checksum)
            .remove_u32(old_src_ip.to_bits())
            .remove_u32(old_dst_ip.to_bits())
            .remove_u16(old_src_port)
            .remove_u16(old_dst_port)
            .remove_u16(old_udp_payload.len() as u16)
            .remove_u16(old_udp_payload.len() as u16)
            .remove_u16(channel_number)
            .remove_u16(channel_data_len)
            .add_u32(new_src_ip.to_bits())
            .add_u32(new_dst_ip.to_bits())
            .add_u16(new_src_port)
            .add_u16(new_dst_port)
            .add_u16(new_udp_payload.len() as u16)
            .add_u16(new_udp_payload.len() as u16)
            .into_udp_checksum();

        assert_eq!(computed_checksum, outgoing_checksum)
    }
}
