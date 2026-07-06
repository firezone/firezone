//! Internet checksum (RFC 1071) helpers for fixing up split / coalesced segments.

use std::net::{Ipv4Addr, Ipv6Addr};

/// Sums `bytes` as big-endian 16-bit words into a ones-complement accumulator.
///
/// The result is unfolded; combine multiple sums by addition and finish with [`fold`].
pub fn sum(bytes: &[u8], initial: u64) -> u64 {
    let mut acc = initial;

    let mut chunks = bytes.chunks_exact(2);
    for chunk in chunks.by_ref() {
        acc += u64::from(u16::from_be_bytes([chunk[0], chunk[1]]));
    }

    if let [last] = chunks.remainder() {
        acc += u64::from(u16::from_be_bytes([*last, 0]));
    }

    acc
}

/// Folds a ones-complement accumulator into a 16-bit checksum value (without complementing).
pub fn fold(mut acc: u64) -> u16 {
    while acc > 0xFFFF {
        acc = (acc & 0xFFFF) + (acc >> 16);
    }

    acc as u16
}

/// The pseudo-header sum for an IPv4 TCP / UDP checksum.
pub fn pseudo_header_sum_v4(src: Ipv4Addr, dst: Ipv4Addr, protocol: u8, l4_len: usize) -> u64 {
    let mut acc = 0;
    acc = sum(&src.octets(), acc);
    acc = sum(&dst.octets(), acc);
    acc += u64::from(protocol);
    acc += l4_len as u64;

    acc
}

/// The pseudo-header sum for an IPv6 TCP / UDP checksum.
pub fn pseudo_header_sum_v6(src: Ipv6Addr, dst: Ipv6Addr, protocol: u8, l4_len: usize) -> u64 {
    let mut acc = 0;
    acc = sum(&src.octets(), acc);
    acc = sum(&dst.octets(), acc);
    acc += u64::from(protocol);
    acc += l4_len as u64;

    acc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_rfc1071_example() {
        // Example from RFC 1071: 00 01 f2 03 f4 f5 f6 f7 -> sum ddf2 (before complement).
        let acc = sum(&[0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7], 0);

        assert_eq!(fold(acc), 0xddf2);
    }

    #[test]
    fn handles_odd_length() {
        let acc = sum(&[0xab], 0);

        assert_eq!(fold(acc), 0xab00);
    }
}
