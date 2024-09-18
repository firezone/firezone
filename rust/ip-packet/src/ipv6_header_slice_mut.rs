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
}
