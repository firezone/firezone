use aya_ebpf::programs::XdpContext;
use network_types::eth::{EthHdr, EtherType};

use crate::{error::Error, slice_mut_at::slice_mut_at};

pub struct Eth<'a> {
    inner: &'a mut EthHdr,
}

impl<'a> Eth<'a> {
    #[inline(always)]
    pub fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        Ok(Self {
            inner: slice_mut_at::<EthHdr>(ctx, 0)?,
        })
    }

    pub fn ether_type(&self) -> EtherType {
        self.inner.ether_type
    }

    pub fn swap_src_and_dst(&mut self) {
        core::mem::swap(&mut self.inner.src_addr, &mut self.inner.dst_addr);
    }
}
