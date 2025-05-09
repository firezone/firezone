use crate::slice_utils::write_to_offset_unchecked;
use etherparse::Ipv6HeaderSlice;

pub struct Ipv6HeaderSliceMut<'a> {
    slice: &'a mut [u8],
}

impl<'a> Ipv6HeaderSliceMut<'a> {
    /// Creates a new [`Ipv6HeaderSliceMut`].
    pub fn from_slice(
        slice: &'a mut [u8],
    ) -> Result<Self, etherparse::err::ipv6::HeaderSliceError> {
        Ipv6HeaderSlice::from_slice(slice)?;

        Ok(Self { slice })
    }

    pub fn set_source(&mut self, src: [u8; 16]) {
        // Safety: Slice it at least of length 40 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 8, src) };
    }

    pub fn set_destination(&mut self, dst: [u8; 16]) {
        // Safety: Slice it at least of length 40 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 24, dst) };
    }

    /// Sets the ECN bits in the IPv6 header.
    ///
    /// Doing this is a bit trickier than for IPv4 due to the layout of the IPv6 header:
    ///
    /// ```text
    /// 0               8              16              24              32
    /// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    /// |Version| Traffic Class |           Flow Label                  |
    /// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    /// ```
    ///
    /// The Traffic Class field (of which the lower two bits are used for ECN) is split across
    /// two bytes. Thus, to set the ECN bits, we actually need to set bit 3 & 4 of the second byte.
    pub fn set_ecn(&mut self, ecn: u8) {
        let mask = 0b1100_1111; // Mask to clear the ecn bits.
        let ecn = ecn << 4; // Shift the ecn bits to the correct position (so they fit the mask above).

        let second_byte = self.slice[1];
        let new = second_byte & mask | ecn;

        unsafe { write_to_offset_unchecked(self.slice, 1, [new]) };
    }
}
