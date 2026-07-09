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

    pub fn into_ip_checksum(self) -> u16 {
        !self.inner
    }

    pub fn into_udp_checksum(self) -> u16 {
        // RFC 768, Section 3.1 states that we must invert the final computed checksum if it came
        // out to be zero.
        let check = !self.inner;

        if check == 0 { 0xFFFF } else { check }
    }
}

#[inline(always)]
fn fold_u32_into_u16(mut csum: u32) -> u16 {
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);

    csum as u16
}

#[inline(never)]
fn fold_u128_into_u16(mut csum: u128) -> u16 {
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);
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
        let updated = ChecksumUpdate::new(0xdd2f)
            .remove_u16(0x5555)
            .add_u16(0x3285)
            .into_ip_checksum();

        assert_eq!(updated, 0x0000);
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
    fn udp_checksum_never_returns_zero() {
        // A patch whose result is zero must be transmitted as all-ones for UDP.
        let updated = ChecksumUpdate::new(0xFFFF).into_udp_checksum();

        assert_eq!(updated, 0xFFFF);
    }
}
