//! Internet checksum (RFC 1071) helpers for fixing up split / coalesced segments.

use std::net::{Ipv4Addr, Ipv6Addr};

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
