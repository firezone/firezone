use aya_ebpf::programs::XdpContext;
use aya_log_ebpf::debug;
use network_types::eth::{EthHdr, EtherType};

use crate::{error::Error, ref_mut_at::ref_mut_at};

pub struct Eth<'a> {
    inner: &'a mut EthHdr,
    ctx: &'a XdpContext,
}

impl<'a> Eth<'a> {
    /// # SAFETY
    ///
    /// You must not create multiple [`Eth`] structs at same time.
    #[inline(always)]
    pub unsafe fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        Ok(Self {
            // Safety: We are forwarding the constraint.
            inner: unsafe { ref_mut_at::<EthHdr>(ctx, 0) }?,
            ctx,
        })
    }

    pub fn ether_type(&self) -> EtherType {
        self.inner.ether_type
    }

    /// Swap source and destination MAC addresses for TURN traffic.
    ///
    /// NOTE: This only works when all channel data traffic uses the same next hop for relayed
    /// traffic as the one it received the packets from. In all cases where the production relays
    /// are deployed, this will be a safe assumption to make. We avoid swapping MAC for traffic
    /// passed to userspace in case the above assumption does not hold true.
    #[inline(always)]
    pub fn swap_macs(self) -> Result<(), Error> {
        let old_src = self.inner.src_addr;
        let old_dst = self.inner.dst_addr;

        self.inner.src_addr = old_dst;
        self.inner.dst_addr = old_src;

        debug!(
            self.ctx,
            "ETH header swap: src {:mac} -> {:mac}; dst {:mac} -> {:mac}",
            old_src,
            old_dst,
            old_dst,
            old_src,
        );

        Ok(())
    }
}
