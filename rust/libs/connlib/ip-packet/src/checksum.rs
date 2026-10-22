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
///
/// The ones-complement sum is independent of byte order up to a final byte swap (RFC 1071),
/// so the bytes are summed as native-endian `u64` words and only the folded result is swapped.
pub fn sum(bytes: &[u8], initial: u64) -> u64 {
    let (chunks, rest) = bytes.as_chunks::<32>();

    // The tail starts at an even offset, so zero-padding it keeps every byte in its 16-bit word.
    let mut tail = [0u8; 32];
    tail[..rest.len()].copy_from_slice(rest);

    // Independent accumulators let the CPU run the additions in parallel.
    let mut accs = [0u128; 4];
    let mut add = |chunk: &[u8; 32]| {
        for (acc, word) in accs.iter_mut().zip(chunk.as_chunks::<8>().0) {
            *acc += u128::from(u64::from_ne_bytes(*word));
        }
    };
    for chunk in chunks {
        add(chunk);
    }
    add(&tail);

    let acc = accs.iter().sum::<u128>();
    let (acc, carry) = (acc as u64).overflowing_add((acc >> 64) as u64);

    initial + u64::from(u16::from_be(fold(acc + u64::from(carry))))
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
        for len in 0..100usize {
            let bytes: Vec<u8> = (0..len)
                .map(|i| (i as u8).wrapping_mul(37).wrapping_add(3))
                .collect();

            assert_eq!(fold(sum(&bytes, 0)), naive(&bytes, 0), "len={len}");
        }
    }

    #[cfg(feature = "proptest")]
    #[test_strategy::proptest()]
    fn matches_naive_sum(
        #[strategy(proptest::collection::vec(proptest::arbitrary::any::<u8>(), 0..=65535))]
        bytes: Vec<u8>,
        #[strategy(0..=0xFFFF_FFFFu64)] initial: u64,
    ) {
        proptest::prop_assert_eq!(fold(sum(&bytes, initial)), naive(&bytes, initial));
    }

    /// Sums one big-endian 16-bit word at a time.
    fn naive(bytes: &[u8], initial: u64) -> u16 {
        let mut acc = initial;
        let (words, remainder) = bytes.as_chunks::<2>();
        for word in words {
            acc += u64::from(u16::from_be_bytes(*word));
        }
        if let [last] = remainder {
            acc += u64::from(u16::from_be_bytes([*last, 0]));
        }
        fold(acc)
    }
}
