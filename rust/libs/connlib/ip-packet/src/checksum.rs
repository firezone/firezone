//! Internet checksum (RFC 1071) computation over byte slices.
//!
//! The mutators on [`IpPacket`](crate::IpPacket) maintain checksums incrementally
//! via [`incremental_inet_checksum::ChecksumUpdate`]; the functions here compute
//! checksum values from scratch.

use std::net::{Ipv4Addr, Ipv6Addr};

use crate::IpProtocol;

/// Sums `bytes` as big-endian 16-bit words into a ones-complement accumulator.
///
/// The result is unfolded; combine multiple sums by addition and finish with [`fold`].
pub fn sum(bytes: &[u8], initial: u64) -> u64 {
    let mut acc = initial;

    // Sum eight bytes at a time. Folding a wider big-endian word is equivalent to summing its
    // 16-bit halves separately: the high bits just carry down later in [`fold`]. A `u64`
    // accumulator holds the sum of ~8k such words without overflowing, so no intermediate
    // fold is needed for a single packet (at most 65535 bytes).
    let mut chunks = bytes.chunks_exact(8);
    for chunk in chunks.by_ref() {
        let word = u64::from_be_bytes(chunk.try_into().expect("chunk is 8 bytes"));
        acc += word >> 32;
        acc += word & 0xFFFF_FFFF;
    }

    let mut tail = chunks.remainder().chunks_exact(2);
    for chunk in tail.by_ref() {
        acc += u64::from(u16::from_be_bytes([chunk[0], chunk[1]]));
    }

    if let [last] = tail.remainder() {
        acc += u64::from(u16::from_be_bytes([*last, 0]));
    }

    acc
}

/// Folds a ones-complement accumulator into a 16-bit value without complementing it.
pub fn fold(mut acc: u64) -> u16 {
    while acc > 0xFFFF {
        acc = (acc & 0xFFFF) + (acc >> 16);
    }

    acc as u16
}

/// Computes the pseudo-header sum for an IPv4 transport checksum.
pub fn pseudo_header_sum_v4(
    source: Ipv4Addr,
    destination: Ipv4Addr,
    protocol: IpProtocol,
    l4_len: usize,
) -> u64 {
    let mut acc = 0;
    acc = sum(&source.octets(), acc);
    acc = sum(&destination.octets(), acc);
    acc += u64::from(protocol.0);
    acc += l4_len as u64;

    acc
}

/// Computes the pseudo-header sum for an IPv6 transport checksum.
pub fn pseudo_header_sum_v6(
    source: Ipv6Addr,
    destination: Ipv6Addr,
    protocol: IpProtocol,
    l4_len: usize,
) -> u64 {
    let mut acc = 0;
    acc = sum(&source.octets(), acc);
    acc = sum(&destination.octets(), acc);
    acc += u64::from(protocol.0);
    acc += l4_len as u64;

    acc
}

/// Computes the checksum over an IPv4 header, ignoring the stored checksum field.
pub(crate) fn ipv4_header_checksum(header: &[u8]) -> u16 {
    const CHECKSUM_FIELD: usize = 10;

    !fold(sum_with_zeroed_checksum(header, CHECKSUM_FIELD, 0))
}

/// Computes the checksum of a transport-layer segment, ignoring the stored checksum field.
///
/// `l4` must span the entire transport header + payload.
/// For ICMPv4, pass a pseudo-header sum of `0`; all other protocols' checksums
/// cover the IP pseudo-header.
pub(crate) fn l4_checksum(pseudo_header_sum: u64, l4: &[u8], checksum_field: usize) -> u16 {
    !fold(sum_with_zeroed_checksum(
        l4,
        checksum_field,
        pseudo_header_sum,
    ))
}

fn sum_with_zeroed_checksum(data: &[u8], checksum_field: usize, initial: u64) -> u64 {
    let acc = sum(&data[..checksum_field], initial);

    sum(&data[checksum_field + 2..], acc)
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

    #[test]
    fn matches_naive_sum_over_varied_lengths() {
        // The straightforward 16-bit-word sum, against which the wide-word `sum` must agree
        // across every chunk / tail / remainder combination.
        fn naive(bytes: &[u8]) -> u16 {
            let mut acc = 0u64;
            let mut words = bytes.chunks_exact(2);
            for word in words.by_ref() {
                acc += u64::from(u16::from_be_bytes([word[0], word[1]]));
            }
            if let [last] = words.remainder() {
                acc += u64::from(u16::from_be_bytes([*last, 0]));
            }
            fold(acc)
        }

        for len in 0..40usize {
            let bytes: Vec<u8> = (0..len)
                .map(|i| (i as u8).wrapping_mul(37).wrapping_add(3))
                .collect();

            assert_eq!(fold(sum(&bytes, 0)), naive(&bytes), "len={len}");
        }
    }
}
