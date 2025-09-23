use aya_ebpf::{helpers::generated::bpf_xdp_adjust_head, programs::XdpContext};

use crate::try_handle_turn::Error;

#[inline(always)]
pub fn adjust_head(ctx: &XdpContext, size: i32) -> Result<(), Error> {
    // SAFETY: The attach mode and NIC driver support headroom adjustment by `size` bytes.
    let ret = unsafe { bpf_xdp_adjust_head(ctx.ctx, size) };
    if ret < 0 {
        return Err(Error::XdpAdjustHeadFailed);
    }

    Ok(())
}
