//! Incremental updates to Internet checksums.
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

#[derive(Default)]
pub struct ChecksumUpdate {
    inner: u16,
}

impl ChecksumUpdate {
    pub fn new(checksum: u16) -> Self {
        Self { inner: !checksum }
    }

    pub fn remove_u16(self, val: u16) -> Self {
        self.ones_complement_add(!val)
    }

    pub fn remove_u32(self, val: u32) -> Self {
        self.remove_u16(fold_u32_into_u16(val))
    }

    pub fn add_u16(self, val: u16) -> Self {
        self.ones_complement_add(val)
    }

    pub fn add_u32(self, val: u32) -> Self {
        self.add_u16(fold_u32_into_u16(val))
    }

    pub fn add_update(self, update: ChecksumUpdate) -> Self {
        self.add_u16(update.inner)
    }

    fn ones_complement_add(self, val: u16) -> Self {
        let (res, carry) = self.inner.overflowing_add(val);

        Self {
            inner: res + (carry as u16),
        }
    }

    pub fn into_checksum(self) -> u16 {
        !self.inner
    }
}

#[inline(always)]
fn fold_u32_into_u16(mut csum: u32) -> u16 {
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);

    csum as u16
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
            old_udp_payload.to_vec(),
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
            new_udp_payload.to_vec(),
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
            .into_checksum();

        assert_eq!(computed_checksum, outgoing_checksum)
    }
}
