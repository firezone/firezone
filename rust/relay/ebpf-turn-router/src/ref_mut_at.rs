use aya_ebpf::programs::XdpContext;

use crate::error::Error;

/// Returns a mutable reference to a type `T` at the specified offset in the packet data.
///
/// The length is based on the size of `T` and the bytes at the specified offset will simply be cast into `T`.
/// `T` should therefore most definitely be `repr(C)`.
#[inline(always)]
pub(crate) fn ref_mut_at<T>(ctx: &XdpContext, offset: usize) -> Result<&mut T, Error> {
    let start = ctx.data();
    let end = ctx.data_end();
    let len = core::mem::size_of::<T>();

    if start + offset + len > end {
        return Err(Error::PacketTooShort);
    }

    let ptr = (start + offset) as *mut T;

    // SAFETY: Pointer to packet is always valid and we checked the length.
    Ok(unsafe { &mut *ptr })
}
