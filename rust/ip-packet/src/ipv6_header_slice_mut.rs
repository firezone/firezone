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
        unsafe { self.write_to_offset(8, src) };
    }

    pub fn set_destination(&mut self, dst: [u8; 16]) {
        // Safety: Slice it at least of length 40 as checked in the ctor.
        unsafe { self.write_to_offset(24, dst) };
    }

    /// Writes the given byte-array to the specified index.
    ///
    /// # Safety
    ///
    /// `offset` + `bytes.len()` must be within the slice.
    unsafe fn write_to_offset<const N: usize>(&mut self, offset: usize, bytes: [u8; N]) {
        debug_assert!(offset + N < self.slice.len());

        let (_front, rest) = unsafe { self.slice.split_at_mut_unchecked(offset) };
        let (target, _rest) = unsafe { rest.split_at_mut_unchecked(N) };

        target.copy_from_slice(&bytes)
    }
}
