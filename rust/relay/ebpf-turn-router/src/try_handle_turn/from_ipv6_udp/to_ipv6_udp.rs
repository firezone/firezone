use aya_ebpf::programs::XdpContext;
use ebpf_shared::PortAndPeerV6;

use crate::try_handle_turn::Error;

#[inline(always)]
pub fn to_ipv6_udp(ctx: &XdpContext, pp: &PortAndPeerV6) -> Result<(), Error> {
    Ok(())
}
