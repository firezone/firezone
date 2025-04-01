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

    pub fn update(self, new_dst: [u8; 6]) {
        self.inner.src_addr = self.inner.dst_addr;
        self.inner.dst_addr = new_dst;
    }
}
