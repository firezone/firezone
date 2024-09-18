/// Writes the given byte-array to the slice at the specified index.
///
/// # Safety
///
/// `offset` + `bytes.len()` must be within the slice.
pub unsafe fn write_to_offset_unchecked<const N: usize>(
    slice: &mut [u8],
    offset: usize,
    bytes: [u8; N],
) {
    debug_assert!(offset + N <= slice.len());

    let (_front, rest) = unsafe { slice.split_at_mut_unchecked(offset) };
    let (target, _rest) = unsafe { rest.split_at_mut_unchecked(N) };

    target.copy_from_slice(&bytes)
}
