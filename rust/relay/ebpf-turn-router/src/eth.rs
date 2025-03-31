use aya_ebpf::programs::XdpContext;
use network_types::eth::{EthHdr, EtherType};

use crate::{error::Error, mut_ptr_at::mut_ptr_at};

pub struct Eth<'a> {
    inner: &'a mut EthHdr,
}

impl<'a> Eth<'a> {
    pub fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        let hdr = unsafe { &mut *mut_ptr_at::<EthHdr>(ctx, 0)? };

        Ok(Self { inner: hdr })
    }

    pub fn ether_type(&self) -> EtherType {
        self.inner.ether_type
    }

    pub fn swap_src_and_dst(&mut self) {
        core::mem::swap(&mut self.inner.src_addr, &mut self.inner.dst_addr);
    }
}
