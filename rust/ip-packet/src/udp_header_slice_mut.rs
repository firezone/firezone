use crate::slice_utils::write_to_offset_unchecked;
use etherparse::UdpHeaderSlice;

pub struct UdpHeaderSliceMut<'a> {
    slice: &'a mut [u8],
}

impl<'a> UdpHeaderSliceMut<'a> {
    /// Creates a new [`UdpHeaderSliceMut`].
    pub fn from_slice(slice: &'a mut [u8]) -> Result<Self, etherparse::err::LenError> {
        UdpHeaderSlice::from_slice(slice)?;

        Ok(Self { slice })
    }

    pub fn get_source_port(&self) -> u16 {
        u16::from_be_bytes([self.slice[0], self.slice[1]])
    }

    pub fn get_destination_port(&self) -> u16 {
        u16::from_be_bytes([self.slice[2], self.slice[3]])
    }

    pub fn set_source_port(&mut self, src: u16) {
        // Safety: Slice it at least of length 8 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 0, src.to_be_bytes()) };
    }

    pub fn set_destination_port(&mut self, dst: u16) {
        // Safety: Slice it at least of length 8 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 2, dst.to_be_bytes()) };
    }

    pub fn set_length(&mut self, length: u16) {
        // Safety: Slice it at least of length 8 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 4, length.to_be_bytes()) };
    }

    pub fn set_checksum(&mut self, checksum: u16) {
        // Safety: Slice it at least of length 8 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 6, checksum.to_be_bytes()) };
    }

    /// Sets the UDP payload and updates the length field.
    ///
    /// The `payload` must fit within the remaining slice after the 8-byte UDP header.
    /// If the payload is too large, this method will panic.
    pub fn set_payload(&mut self, payload: &[u8]) {
        let udp_header_len = 8;
        let total_len = udp_header_len + payload.len();

        // Check if the payload fits within the slice
        assert!(
            total_len <= self.slice.len(),
            "Payload too large for UDP packet buffer: {} bytes needed, {} bytes available",
            total_len,
            self.slice.len()
        );

        // Update the payload
        self.slice[udp_header_len..udp_header_len + payload.len()].copy_from_slice(payload);

        // Update the length field
        self.set_length(total_len as u16);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use etherparse::PacketBuilder;

    #[test]
    fn smoke() {
        let mut buf = Vec::new();

        PacketBuilder::ipv4([0u8; 4], [0u8; 4], 0)
            .udp(10, 20)
            .write(&mut buf, &[])
            .unwrap();

        let mut slice = UdpHeaderSliceMut::from_slice(&mut buf[20..]).unwrap();

        slice.set_source_port(30);
        slice.set_destination_port(40);
        slice.set_length(50);
        slice.set_checksum(60);

        let slice = UdpHeaderSlice::from_slice(&buf[20..]).unwrap();

        assert_eq!(slice.source_port(), 30);
        assert_eq!(slice.destination_port(), 40);
        assert_eq!(slice.length(), 50);
        assert_eq!(slice.checksum(), 60);
    }

    #[test]
    fn set_payload_updates_payload_and_length() {
        let mut buf = vec![0; 20 + 8 + 10]; // IP header (20) + UDP header (8) + payload space (10)

        PacketBuilder::ipv4([0u8; 4], [0u8; 4], 0)
            .udp(10, 20)
            .write(&mut buf, &[1, 2, 3])
            .unwrap();

        let mut slice = UdpHeaderSliceMut::from_slice(&mut buf[20..]).unwrap();

        let new_payload = vec![4, 5, 6, 7];
        slice.set_payload(&new_payload);

        let updated_slice = UdpHeaderSlice::from_slice(&buf[20..]).unwrap();
        assert_eq!(updated_slice.length(), 8 + new_payload.len() as u16);

        // Manually extract payload (after 8-byte header)
        let payload = &buf[20 + 8..20 + 8 + new_payload.len()];
        assert_eq!(payload, &new_payload);
    }

    #[test]
    #[should_panic(expected = "Payload too large for UDP packet buffer")]
    fn set_payload_panics_on_too_large_payload() {
        let mut buf = vec![0; 20 + 8 + 5]; // IP header (20) + UDP header (8) + 5 bytes payload space

        PacketBuilder::ipv4([0u8; 4], [0u8; 4], 0)
            .udp(10, 20)
            .write(&mut buf, &[1, 2, 3])
            .unwrap();

        let mut slice = UdpHeaderSliceMut::from_slice(&mut buf[20..]).unwrap();

        let oversized_payload = vec![1, 2, 3, 4, 5, 6]; // 6 bytes > 5 bytes available
        slice.set_payload(&oversized_payload);
    }
}
