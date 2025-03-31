use aya_ebpf::programs::XdpContext;

use crate::error::Error;

#[inline(always)]
pub(crate) fn mut_ptr_at<T>(ctx: &XdpContext, offset: usize) -> Result<*mut T, Error> {
    let start = ctx.data();
    let end = ctx.data_end();
    let len = core::mem::size_of::<T>();

    if start + offset + len > end {
        return Err(Error::PacketTooShort);
    }

    Ok((start + offset) as *mut T)
}
