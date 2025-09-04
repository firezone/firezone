use aya_ebpf::programs::XdpContext;
use ebpf_shared::ClientAndChannelV6;

use crate::try_handle_turn::Error;

#[inline(always)]
pub fn to_ipv6_channel(ctx: &XdpContext, cc: &ClientAndChannelV6) -> Result<(), Error> {
    Ok(())
}
