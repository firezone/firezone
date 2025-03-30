use crate::{Error, checksum::ChecksumUpdate, slice_mut_at::slice_mut_at};
use aya_ebpf::programs::XdpContext;
use aya_log_ebpf::debug;
use etherparse::{Ethernet2Header, Ipv4Header, UdpHeader, UdpHeaderSlice};
use etherparse_ext::UdpHeaderSliceMut;

/// Represents a UDP header within our packet.
pub struct Udp<'a> {
    src: u16,
    dst: u16,
    len: u16,
    checksum: u16,

    ctx: &'a XdpContext,

    /// Mutable slice of the UDP header, allows us to modify the header in-place.
    slice_mut: UdpHeaderSliceMut<'a>,
}

impl<'a> Udp<'a> {
    pub fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        let slice =
            slice_mut_at::<{ UdpHeader::LEN }>(ctx, Ethernet2Header::LEN + Ipv4Header::MIN_LEN)?;
        let udp_slice = UdpHeaderSlice::from_slice(slice).map_err(|_| Error::ParseUdpHeader)?;

        Ok(Self {
            src: udp_slice.source_port(),
            dst: udp_slice.destination_port(),
            len: udp_slice.length(),
            checksum: udp_slice.checksum(),
            ctx,
            slice_mut: {
                // SAFETY: We parsed the slice as a UDP header above.
                unsafe { UdpHeaderSliceMut::from_slice_unchecked(slice) }
            },
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

    /// Update this packet with a new source, destination, and length.
    pub fn update(
        mut self,
        ip_pseudo_header: ChecksumUpdate,
        new_src: u16,
        new_dst: u16,
        new_len: u16,
    ) {
        self.slice_mut.set_source_port(new_src);
        self.slice_mut.set_destination_port(new_dst);
        self.slice_mut.set_length(new_len);

        let ip_pseudo_header = ip_pseudo_header.remove_u16(self.len).add_u16(new_len);

        if crate::config::udp_checksum_enabled() {
            self.slice_mut.set_checksum(
                ChecksumUpdate::new(self.checksum)
                    .add_update(ip_pseudo_header)
                    .remove_u16(self.len)
                    .add_u16(new_len)
                    .remove_u16(self.src)
                    .add_u16(self.src)
                    .remove_u16(self.dst)
                    .add_u16(self.dst)
                    .into_checksum(),
            );
        } else {
            self.slice_mut.set_checksum(0);
        }

        debug!(
            self.ctx,
            "UDP header update: src {} -> {}; dst {} -> {}", self.src, new_src, self.dst, new_dst,
        );
    }
}
