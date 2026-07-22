//! Internet checksum (RFC 1071) computation over byte slices.
//!
//! The mutators on [`IpPacket`](crate::IpPacket) maintain checksums incrementally
//! via [`incremental_inet_checksum::ChecksumUpdate`]; the functions here compute
//! a checksum from scratch and serve as the ground truth, e.g. when creating new
//! packets or when finalising packets serialised by an external stack.

use std::net::{Ipv4Addr, Ipv6Addr};

use ingot::ip::IpProtocol;

/// Computes the checksum over an IPv4 header, ignoring the stored checksum field.
pub(crate) fn ipv4_header_checksum(header: &[u8]) -> u16 {
    const CHECKSUM_FIELD: usize = 10;

    finalize(sum_with_zeroed_checksum(header, CHECKSUM_FIELD))
}

/// Computes the checksum of a transport-layer segment, ignoring the stored checksum field.
///
/// `l4` must span the entire transport header + payload.
/// For ICMPv4, pass a pseudo-header sum of `0`; all other protocols' checksums
/// cover the IP pseudo-header.
pub(crate) fn l4_checksum(pseudo_header_sum: u32, l4: &[u8], checksum_field: usize) -> u16 {
    finalize(pseudo_header_sum + sum_with_zeroed_checksum(l4, checksum_field))
}

pub(crate) fn pseudo_header_v4(
    source: Ipv4Addr,
    destination: Ipv4Addr,
    protocol: IpProtocol,
    l4_len: usize,
) -> u32 {
    sum_be_words_of(&source.octets())
        + sum_be_words_of(&destination.octets())
        + protocol.0 as u32
        + l4_len as u32
}

pub(crate) fn pseudo_header_v6(
    source: Ipv6Addr,
    destination: Ipv6Addr,
    protocol: IpProtocol,
    l4_len: usize,
) -> u32 {
    sum_be_words_of(&source.octets())
        + sum_be_words_of(&destination.octets())
        + protocol.0 as u32
        + l4_len as u32
}

fn sum_with_zeroed_checksum(data: &[u8], checksum_field: usize) -> u32 {
    sum_be_words_of(&data[..checksum_field]) + sum_be_words_of(&data[checksum_field + 2..])
}

fn sum_be_words_of(data: &[u8]) -> u32 {
    let mut chunks = data.chunks_exact(2);
    let mut sum = chunks
        .by_ref()
        .map(|c| u16::from_be_bytes([c[0], c[1]]) as u32)
        .sum::<u32>();

    if let [byte] = chunks.remainder() {
        sum += u16::from_be_bytes([*byte, 0]) as u32;
    }

    sum
}

fn finalize(mut sum: u32) -> u16 {
    while sum > 0xFFFF {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    !(sum as u16)
}
