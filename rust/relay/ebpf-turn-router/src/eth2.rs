use aya_ebpf::programs::XdpContext;
use etherparse::{EtherType, Ethernet2Header, Ethernet2HeaderSlice};

use crate::{error::Error, slice_mut_at};

pub struct Eth2 {
    ty: EtherType,
}

impl Eth2 {
    pub fn parse(ctx: &XdpContext) -> Result<Self, Error> {
        let slice = slice_mut_at::<{ Ethernet2Header::LEN }>(ctx, 0)?;
        let eth =
            Ethernet2HeaderSlice::from_slice(slice).map_err(|_| Error::ParseEthernet2Header)?;

        Ok(Self {
            ty: eth.ether_type(),
        })
    }

    pub fn ether_type(&self) -> EtherType {
        self.ty
    }
}
