use aya_ebpf::programs::XdpContext;
use ebpf_shared::PortAndPeerV4;

use crate::try_handle_turn::Error;

#[inline(always)]
pub fn to_ipv4_udp(ctx: &XdpContext, pp: &PortAndPeerV4) -> Result<(), Error> {
    Ok(())
}
