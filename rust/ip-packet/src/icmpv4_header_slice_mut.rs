use crate::slice_utils::write_to_offset_unchecked;
use etherparse::{
    Icmpv4Slice,
    icmpv4::{TYPE_ECHO_REPLY, TYPE_ECHO_REQUEST},
};

pub struct Icmpv4HeaderSliceMut<'a> {
    slice: &'a mut [u8],
}

impl<'a> Icmpv4HeaderSliceMut<'a> {
    /// Creates a new [`Icmpv4HeaderSliceMut`].
    pub fn from_slice(slice: &'a mut [u8]) -> Result<Self, etherparse::err::LenError> {
        Icmpv4Slice::from_slice(slice)?;

        Ok(Self { slice })
    }

    pub fn set_checksum(&mut self, checksum: u16) {
        // Safety: Slice is at least of length 8 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 2, checksum.to_be_bytes()) };
    }

    pub fn set_identifier(&mut self, id: u16) {
        debug_assert!(
            self.is_echo_request_or_reply(),
            "ICMP identifier only exists for echo requests and replies"
        );

        // Safety: Slice is at least of length 8 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 4, id.to_be_bytes()) };
    }

    pub fn set_sequence(&mut self, seq: u16) {
        debug_assert!(
            self.is_echo_request_or_reply(),
            "ICMP sequence only exists for echo requests and replies"
        );

        // Safety: Slice is at least of length 8 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 6, seq.to_be_bytes()) };
    }

    fn is_echo_request_or_reply(&self) -> bool {
        let ty = self.slice[0];

        ty == TYPE_ECHO_REPLY || ty == TYPE_ECHO_REQUEST
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use etherparse::{Icmpv4Type, PacketBuilder};

    #[test]
    fn smoke() {
        let mut buf = Vec::new();

        PacketBuilder::ipv4([0u8; 4], [0u8; 4], 0)
            .icmpv4_echo_request(10, 20)
            .write(&mut buf, &[])
            .unwrap();

        let mut slice = Icmpv4HeaderSliceMut::from_slice(&mut buf[20..]).unwrap();

        slice.set_identifier(30);
        slice.set_sequence(40);
        slice.set_checksum(50);

        let slice = Icmpv4Slice::from_slice(&buf[20..]).unwrap();

        let Icmpv4Type::EchoRequest(header) = slice.header().icmp_type else {
            panic!("Unexpected ICMP header");
        };

        assert_eq!(header.id, 30);
        assert_eq!(header.seq, 40);
        assert_eq!(slice.checksum(), 50);
    }
}
