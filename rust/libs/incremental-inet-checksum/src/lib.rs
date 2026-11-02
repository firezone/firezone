//! Incremental updates to Internet checksums (RFC 1071 / RFC 1624).
//!
//! The Internet checksum is the one's complement of the one's complement sum of certain 16-bit words.
//! The use of one's complement arithmetic allows us to make incremental updates to a checksum without requiring a full re-computation.
//!
//! That is what we are implementing in this module.
//! There are three things you need to know:
//!
//! 1. The one's complement of a number `x` is `!x`.
//! 2. Addition in one's complement arithmetic is the same as regular addition, except that upon overflow, we add an additional bit.
//! 3. Subtraction in one's complement arithmetic is implemented as the addition of the one's complement of the number to be subtracted.
//!
//! This allows us to e.g. take an existing IP header checksum and update it to account for just the destination address changing.
//!
//! To use this module, create a new instance of [`ChecksumUpdate`] from the old checksum and then chain the appropriate functions on it.
//! For example, if you are changing the source port of a UDP packet, you want to:
//! - [`remove_u16`](ChecksumUpdate::remove_u16) the old port
//! - [`add_u16`](ChecksumUpdate::add_u16) the new port
//!
//! This will adjust the checksum as if it would have been computed for the packet with the new port.
//!
//! When re-routing packets, we often send from our own address.
//! In other words, the previous destination becomes the new source.
//! In that case, it is common to optimise the checksum update by not removing the old destination at all.
//! Instead we are basically replacing the old source with the new destination.
//! Checksum computation is commutative, i.e. it doesn't care in which order the individual fields got added.
//!
//! This crate is `no_std` and free of unbounded loops so that it can also be used from eBPF programs.

#![no_std]

#[derive(Default)]
#[repr(transparent)]
pub struct ChecksumUpdate {
    inner: u16,
}

impl ChecksumUpdate {
    pub fn new(checksum: u16) -> Self {
        Self { inner: !checksum }
    }

    #[must_use]
    pub fn remove_u16(self, val: u16) -> Self {
        self.ones_complement_add(!val)
    }

    #[must_use]
    pub fn remove_u32(self, val: u32) -> Self {
        self.remove_u16(fold_u32_into_u16(val))
    }

    #[must_use]
    pub fn remove_u128(self, val: u128) -> Self {
        self.remove_u16(fold_u128_into_u16(val))
    }

    #[must_use]
    pub fn add_u16(self, val: u16) -> Self {
        self.ones_complement_add(val)
    }

    #[must_use]
    pub fn add_u32(self, val: u32) -> Self {
        self.add_u16(fold_u32_into_u16(val))
    }

    #[must_use]
    pub fn add_u128(self, val: u128) -> Self {
        self.add_u16(fold_u128_into_u16(val))
    }

    #[inline(always)]
    fn ones_complement_add(self, val: u16) -> Self {
        let (res, carry) = self.inner.overflowing_add(val);

        Self {
            inner: res + (carry as u16),
        }
    }

    /// Finalizes the update into an IP-style checksum (also used by TCP and ICMP).
    ///
    /// A zero checksum is always emitted as `0xFFFF`, never as `0x0000`: one's
    /// complement has two representations of zero and the running sum can land on
    /// either one for the same underlying value, e.g. removing a zero-valued field adds
    /// `!0 = 0xFFFF` and turns +0 into -0. Whether a checksum of `0x0000` verifies
    /// depends on which zero the covered data actually sums to: for data summing to -0
    /// it does, for all-zero data (which sums to +0) receivers compute an
    /// end-around-carry sum of `0x0000` instead of the required `0xFFFF` and drop the
    /// packet. A checksum of `0xFFFF` verifies in both cases, so it is the only safe
    /// way to emit "zero". Consequently, a from-scratch computation may arrive at
    /// `0x0000` where this function returns `0xFFFF`; validators comparing the two must
    /// treat them as equivalent rather than compare for strict equality.
    pub fn into_ip_checksum(self) -> u16 {
        non_zero_complement(self.inner)
    }

    pub fn into_udp_checksum(self) -> u16 {
        // RFC 768, Section 3.1 states that we must invert the final computed checksum if it came
        // out to be zero.
        non_zero_complement(self.inner)
    }
}

fn non_zero_complement(inner: u16) -> u16 {
    let checksum = !inner;

    if checksum == 0 { 0xFFFF } else { checksum }
}

#[inline(always)]
fn fold_u32_into_u16(mut csum: u32) -> u16 {
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);

    csum as u16
}

/// Folds the halves of the value first because 128-bit arithmetic is expensive, especially in eBPF.
#[inline(always)]
fn fold_u128_into_u16(csum: u128) -> u16 {
    let (sum, carry) = ((csum >> 64) as u64).overflowing_add(csum as u64);

    // Cannot overflow: with a carry, the sum is at most `u64::MAX - 1`.
    fold_u64_into_u16(sum + carry as u64)
}

#[inline(always)]
fn fold_u64_into_u16(mut csum: u64) -> u16 {
    csum = (csum & 0xffff_ffff) + (csum >> 32);
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);

    csum as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn updates_word_like_rfc1624() {
        // Example from RFC 1624, section 4: checksum 0xdd2f, word 0x5555 becomes 0x3285.
        // The RFC arrives at 0x0000; we emit the equivalent -0 representation because
        // 0x0000 does not verify for all-zero data (see `into_ip_checksum`).
        let updated = ChecksumUpdate::new(0xdd2f)
            .remove_u16(0x5555)
            .add_u16(0x3285)
            .into_ip_checksum();

        assert_eq!(updated, 0xFFFF);
    }

    #[test]
    fn removing_zero_from_all_zero_data_keeps_checksum_valid() {
        // An all-zero ICMP echo message has checksum 0xFFFF (its words sum to +0).
        // Removing and re-adding a zero-valued field must not flip it to 0x0000,
        // which would not verify.
        let updated = ChecksumUpdate::new(0xFFFF)
            .remove_u16(0x0000)
            .add_u16(0x0000)
            .into_ip_checksum();

        assert_eq!(updated, 0xFFFF);
    }

    #[test]
    fn remove_then_add_same_value_is_noop() {
        let updated = ChecksumUpdate::new(0xabcd)
            .remove_u16(0x1234)
            .add_u16(0x1234)
            .into_ip_checksum();

        assert_eq!(updated, 0xabcd);
    }

    #[test]
    fn folds_u128_like_summing_its_words() {
        let edge_cases = [
            0,
            1,
            u128::MAX,
            u128::MAX - 1,
            u64::MAX as u128,
            (u64::MAX as u128) << 64,
            1 << 127,
            0xffff,
            0x1_0000,
        ];
        let mut lcg = 0x2545_f491_4f6c_dd1d_u128;
        let pseudo_random = core::iter::repeat_with(|| {
            lcg = lcg
                .wrapping_mul(0x2360_ed05_1fc6_5da4_4385_df64_9fcc_f645)
                .wrapping_add(0x5851_f42d_4c95_7f2d_1405_7b7e_f767_814f);
            lcg
        });

        for val in edge_cases.into_iter().chain(pseudo_random.take(100_000)) {
            let mut sum = (0..8).map(|i| (val >> (16 * i)) as u16 as u32).sum::<u32>();
            while sum > 0xffff {
                sum = (sum & 0xffff) + (sum >> 16);
            }

            assert_eq!(fold_u128_into_u16(val), sum as u16, "{val:#x}");
        }
    }

    #[test]
    fn udp_checksum_never_returns_zero() {
        // A patch whose result is zero must be transmitted as all-ones for UDP.
        let updated = ChecksumUpdate::new(0xFFFF).into_udp_checksum();

        assert_eq!(updated, 0xFFFF);
    }
}
