use crate::slice_utils::write_to_offset_unchecked;
use etherparse::TcpHeaderSlice;

pub struct TcpHeaderSliceMut<'a> {
    slice: &'a mut [u8],
}

impl<'a> TcpHeaderSliceMut<'a> {
    /// Creates a new [`TcpHeaderSliceMut`].
    pub fn from_slice(slice: &'a mut [u8]) -> Result<Self, etherparse::err::tcp::HeaderSliceError> {
        TcpHeaderSlice::from_slice(slice)?;

        Ok(Self { slice })
    }

    pub fn get_source_port(&self) -> u16 {
        u16::from_be_bytes([self.slice[0], self.slice[1]])
    }

    pub fn get_destination_port(&self) -> u16 {
        u16::from_be_bytes([self.slice[2], self.slice[3]])
    }

    pub fn set_source_port(&mut self, src: u16) {
        // Safety: Slice it at least of length 20 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 0, src.to_be_bytes()) };
    }

    pub fn set_destination_port(&mut self, dst: u16) {
        // Safety: Slice it at least of length 20 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 2, dst.to_be_bytes()) };
    }

    pub fn set_checksum(&mut self, checksum: u16) {
        // Safety: Slice it at least of length 20 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 16, checksum.to_be_bytes()) };
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
            .tcp(10, 20, 0, 0)
            .write(&mut buf, &[])
            .unwrap();

        let mut slice = TcpHeaderSliceMut::from_slice(&mut buf[20..]).unwrap();

        slice.set_source_port(30);
        slice.set_destination_port(40);
        slice.set_checksum(50);

        let slice = TcpHeaderSlice::from_slice(&buf[20..]).unwrap();

        assert_eq!(slice.source_port(), 30);
        assert_eq!(slice.destination_port(), 40);
        assert_eq!(slice.checksum(), 50);
    }
}
