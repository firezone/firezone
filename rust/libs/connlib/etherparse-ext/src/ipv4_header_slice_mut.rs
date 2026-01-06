use crate::slice_utils::write_to_offset_unchecked;
use etherparse::Ipv4HeaderSlice;

pub struct Ipv4HeaderSliceMut<'a> {
    slice: &'a mut [u8],
}

impl<'a> Ipv4HeaderSliceMut<'a> {
    /// Creates a new [`Ipv4HeaderSliceMut`].
    pub fn from_slice(
        slice: &'a mut [u8],
    ) -> Result<Self, etherparse::err::ipv4::HeaderSliceError> {
        Ipv4HeaderSlice::from_slice(slice)?;

        Ok(Self { slice })
    }

    /// Creates a new [`Ipv4HeaderSliceMut`] without checking the slice.
    ///
    /// # Safety
    ///
    /// The caller must guarantee that the slice is at least of length 20.
    pub unsafe fn from_slice_unchecked(slice: &'a mut [u8]) -> Self {
        Self { slice }
    }

    pub fn set_checksum(&mut self, checksum: u16) {
        // Safety: Slice it at least of length 40 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 10, checksum.to_be_bytes()) };
    }

    pub fn set_source(&mut self, src: [u8; 4]) {
        // Safety: Slice it at least of length 20 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 12, src) };
    }

    pub fn set_destination(&mut self, dst: [u8; 4]) {
        // Safety: Slice it at least of length 20 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 16, dst) };
    }

    pub fn set_total_length(&mut self, len: [u8; 2]) {
        // Safety: Slice it at least of length 20 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 2, len) };
    }

    pub fn set_ecn(&mut self, ecn: u8) {
        let current = self.slice[1];
        let new = current & 0b1111_1100 | ecn;

        // Safety: Slice it at least of length 20 as checked in the ctor.
        unsafe { write_to_offset_unchecked(self.slice, 1, [new]) };
    }
}
