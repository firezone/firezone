use crate::slice_utils::write_to_offset_unchecked;
use etherparse::Ipv6HeaderSlice;

pub struct Ipv6HeaderSliceMut<'a> {
    slice: &'a mut [u8],
}

impl<'a> Ipv6HeaderSliceMut<'a> {
    /// Creates a new [`Ipv6HeaderSliceMut`].
    ///
    /// # Safety
    ///
    /// - The byte array must be at least of length 40.
    /// - The IP version must be 6.
    pub unsafe fn from_slice_unchecked(slice: &'a mut [u8]) -> Self {
        debug_assert!(Ipv6HeaderSlice::from_slice(slice).is_ok()); // Debug asserts are no-ops in release mode, so this is still "unchecked".

        Self { slice }
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
