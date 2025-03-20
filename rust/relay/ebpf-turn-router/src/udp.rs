use crate::{checksum::ChecksumUpdate, ipv4::Ipv4, slice_mut_at::slice_mut_at, Error};
use aya_ebpf::programs::XdpContext;
use aya_log_ebpf::debug;
use etherparse::{
    Ethernet2Header, IpNumber, Ipv4Header, Ipv4HeaderSlice, UdpHeader, UdpHeaderSlice,
};
use etherparse_ext::UdpHeaderSliceMut;

pub struct Udp<'a> {
    src: u16,
    dst: u16,
    len: u16,
    checksum: u16,

    ctx: &'a XdpContext,
    slice_mut: UdpHeaderSliceMut<'a>,
}

impl<'a> Udp<'a> {
    pub fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        let slice =
            slice_mut_at::<{ UdpHeader::LEN }>(ctx, Ethernet2Header::LEN + Ipv4Header::MIN_LEN)?;
        let udp_slice = UdpHeaderSlice::from_slice(slice).map_err(|_| Error::UdpHeader)?;

        Ok(Self {
            src: udp_slice.source_port(),
            dst: udp_slice.destination_port(),
            len: udp_slice.length(),
            checksum: udp_slice.checksum(),

            ctx,
            slice_mut: UdpHeaderSliceMut::from_slice(slice).map_err(|_| Error::UdpHeader)?,
        })
    }

    pub fn src(&self) -> u16 {
        self.src
    }

    pub fn dst(&self) -> u16 {
        self.dst
    }

    pub fn len(&self) -> u16 {
        self.len
    }

    pub fn checksum(&self) -> u16 {
        self.checksum
    }

    pub fn reroute(mut self, pseudo_header: ChecksumUpdate, src: u16, dst: u16, len: u16) {
        self.slice_mut.set_source_port(src);
        self.slice_mut.set_destination_port(dst);
        self.slice_mut.set_length(len);

        let ip_pseudo_header = pseudo_header.remove_u16(self.len).add_u16(len);

        self.slice_mut.set_checksum(
            ChecksumUpdate::new(self.checksum)
                .add_update(ip_pseudo_header)
                .remove_u16(self.len)
                .add_u16(len)
                .remove_u16(self.src)
                .add_u16(self.src)
                .remove_u16(self.dst)
                .add_u16(self.dst)
                .into_checksum(),
        );

        debug!(
            self.ctx,
            "UDP header update: src {} -> {}; dst {} -> {}", self.src, new_src, self.dst, new_dst,
        );
    }
}
