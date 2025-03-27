use crate::{Error, checksum::ChecksumUpdate, slice_mut_at::slice_mut_at};
use aya_ebpf::programs::XdpContext;
use aya_log_ebpf::debug;
use etherparse::{Ethernet2Header, IpNumber, Ipv4Header, Ipv4HeaderSlice};
use etherparse_ext::Ipv4HeaderSliceMut;

/// Represents an IPv4 header within our packet.
pub struct Ip4<'a> {
    src: [u8; 4],
    dst: [u8; 4],
    protocol: IpNumber,
    checksum: u16,
    total_len: u16,

    ctx: &'a XdpContext,

    /// Mutable slice of the IPv4 header, allows us to modify the header in-place.
    slice_mut: Ipv4HeaderSliceMut<'a>,
}

impl<'a> Ip4<'a> {
    pub fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        let slice_mut = slice_mut_at::<{ Ipv4Header::MIN_LEN }>(ctx, Ethernet2Header::LEN)?;
        let ipv4_slice =
            Ipv4HeaderSlice::from_slice(slice_mut).map_err(|_| Error::ParseIpv4Header)?;

        // IPv4 packets with options are handled in user-space.
        if usize::from(ipv4_slice.ihl() * 4) != Ipv4Header::MIN_LEN {
            return Err(Error::Ipv4PacketWithOptions);
        }

        Ok(Self {
            ctx,
            src: ipv4_slice.source(),
            dst: ipv4_slice.destination(),
            protocol: ipv4_slice.protocol(),
            checksum: ipv4_slice.header_checksum(),
            total_len: ipv4_slice.total_len(),
            slice_mut: {
                // SAFETY: We parsed the slice as an IPv4 header above.
                unsafe { Ipv4HeaderSliceMut::from_slice_unchecked(slice_mut) }
            },
        })
    }

    pub fn src(&self) -> [u8; 4] {
        self.src
    }

    pub fn dst(&self) -> [u8; 4] {
        self.dst
    }

    pub fn protocol(&self) -> IpNumber {
        self.protocol
    }

    pub fn total_len(&self) -> u16 {
        self.total_len
    }

    /// Update this packet with a new source, destination, and total length.
    ///
    /// Returns a [`ChecksumUpdate`] representing the checksum-difference of the "IP pseudo-header."
    /// which is used in certain L4 protocols (e.g. UDP).
    pub fn update(mut self, new_src: [u8; 4], new_dst: [u8; 4], new_len: u16) -> ChecksumUpdate {
        self.slice_mut.set_source(new_src);
        self.slice_mut.set_destination(new_dst);
        self.slice_mut.set_total_length(new_len.to_be_bytes());

        let ip_pseudo_header = ChecksumUpdate::default()
            .remove_addr(self.src)
            .add_addr(new_src)
            .remove_addr(self.dst)
            .add_addr(new_dst);

        self.slice_mut.set_checksum(
            ChecksumUpdate::new(self.checksum)
                .remove_addr(self.src)
                .add_addr(new_src)
                .remove_addr(self.dst)
                .add_addr(new_dst)
                .remove_u16(self.total_len)
                .add_u16(new_len)
                .into_checksum(),
        );

        debug!(
            self.ctx,
            "IP4 header update: src {:i} -> {:i}; dst {:i} -> {:i}",
            self.src,
            new_src,
            self.dst,
            new_dst,
        );

        ip_pseudo_header
    }
}
