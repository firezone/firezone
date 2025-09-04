use aya_ebpf::programs::XdpContext;
use ebpf_shared::ClientAndChannelV4;

use crate::try_handle_turn::Error;

#[inline(always)]
pub fn to_ipv4_channel(ctx: &XdpContext, cc: &ClientAndChannelV4) -> Result<(), Error> {
    Ok(())
}
