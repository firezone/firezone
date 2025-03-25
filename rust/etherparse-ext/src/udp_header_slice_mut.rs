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

    /// Creates a new [`UdpHeaderSliceMut`] without checking the slice.
    ///
    /// # Safety
    ///
    /// The caller must guarantee that the slice is at least of length 8.
    pub unsafe fn from_slice_unchecked(slice: &'a mut [u8]) -> Self {
        Self { slice }
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
}
