use aya_ebpf::programs::XdpContext;

use crate::error::Error;

/// Returns an immutable reference to a type `T` at the specified offset in the packet data.
///
/// The length is based on the size of `T` and the bytes at the specified offset will simply be cast into `T`.
/// `T` should therefore most definitely be `repr(C)`.
///
/// # SAFETY
///
/// The caller must ensure that the type `T` is valid for the given offset and length.
#[inline(always)]
pub(crate) unsafe fn ref_at<T>(ctx: &XdpContext, offset: usize) -> Result<&T, Error> {
    let checked_addr = check_offset(ctx, offset, core::mem::size_of::<T>())?;

    let ptr = checked_addr as *const T;

    // SAFETY: Pointer to packet is always valid and we checked the length.
    Ok(unsafe { &*ptr })
}

/// Returns a mutable reference to a type `T` at the specified offset in the packet data.
///
/// The length is based on the size of `T` and the bytes at the specified offset will simply be cast into `T`.
/// `T` should therefore most definitely be `repr(C)`.
///
/// # SAFETY
///
/// You must not obtain overlapping mutable references from the context.
#[inline(always)]
#[expect(clippy::mut_from_ref, reason = "The function is unsafe.")]
pub(crate) unsafe fn ref_mut_at<T>(ctx: &XdpContext, offset: usize) -> Result<&mut T, Error> {
    let checked_addr = check_offset(ctx, offset, core::mem::size_of::<T>())?;

    let ptr = checked_addr as *mut T;

    // SAFETY: Pointer to packet is always valid and we checked the length.
    Ok(unsafe { &mut *ptr })
}

fn check_offset(ctx: &XdpContext, offset: usize, len: usize) -> Result<usize, Error> {
    let start = ctx.data();
    let end = ctx.data_end();

    if start + offset + len > end {
        return Err(Error::PacketTooShort);
    }

    Ok(start + offset)
}
