#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod make;

mod buffer_pool;
mod fz_p2p_control;
mod fz_p2p_control_slice;
mod icmp_dest_unreachable;
mod icmpv4_header_slice_mut;
mod icmpv6_header_slice_mut;
mod ipv4_header_slice_mut;
mod ipv6_header_slice_mut;
mod nat46;
mod nat64;
#[cfg(feature = "proptest")]
#[allow(clippy::unwrap_used)]
pub mod proptest;
mod slice_utils;
mod tcp_header_slice_mut;
mod udp_header_slice_mut;

use buffer_pool::Buffer;
pub use etherparse::*;
pub use fz_p2p_control::EventType as FzP2pEventType;
pub use fz_p2p_control_slice::FzP2pControlSlice;
pub use icmp_dest_unreachable::{DestUnreachable, FailedPacket};

#[cfg(all(test, feature = "proptest"))]
mod proptests;

use anyhow::{Context as _, Result, bail};
use icmpv4_header_slice_mut::Icmpv4HeaderSliceMut;
use icmpv6_header_slice_mut::Icmpv6EchoHeaderSliceMut;
use ipv4_header_slice_mut::Ipv4HeaderSliceMut;
use ipv6_header_slice_mut::Ipv6HeaderSliceMut;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use tcp_header_slice_mut::TcpHeaderSliceMut;
use udp_header_slice_mut::UdpHeaderSliceMut;

/// The maximum size of an IP packet we can handle.
pub const MAX_IP_SIZE: usize = 1280;
/// The maximum payload an IP packet can have.
///
/// IPv6 headers are always a fixed size whereas IPv4 headers can vary.
/// The max length of an IPv4 header is > the fixed length of an IPv6 header.
pub const MAX_IP_PAYLOAD: u16 = (MAX_IP_SIZE - etherparse::Ipv4Header::MAX_LEN) as u16;
/// The maximum payload a UDP packet can have.
pub const MAX_UDP_PAYLOAD: u16 = MAX_IP_PAYLOAD - etherparse::UdpHeader::LEN as u16;

/// The maximum size of the payload that Firezone will send between nodes.
///
/// - The TUN device MTU is constrained to 1280 ([`MAX_IP_SIZE`]).
/// - WireGuard adds an overhoad of 32 bytes ([`WG_OVERHEAD`]).
/// - In case NAT46 comes into effect, the size may increase by 20 ([`NAT46_OVERHEAD`]).
/// - In case the connection is relayed, a 4 byte overhead is added ([`DATA_CHANNEL_OVERHEAD`]).
///
/// There is only a single scenario within which all of these apply at once:
/// A client receiving a relayed IPv6 packet from a Gateway from an IPv4-only DNS resource where the sender (i.e. the resource) maxed out the MTU (1280).
/// In that case, the Gateway needs to translate the packet to IPv6, thus increasing the header size by 20 bytes.
/// WireGuard adds its fixed 32-byte overhead and the relayed connections adds its 4 byte overhead.
pub const MAX_FZ_PAYLOAD: usize =
    MAX_IP_SIZE + WG_OVERHEAD + NAT46_OVERHEAD + DATA_CHANNEL_OVERHEAD;
/// Wireguard has a 32-byte overhead (4b message type + 4b receiver idx + 8b packet counter + 16b AEAD tag)
pub const WG_OVERHEAD: usize = 32;
/// In order to do NAT46 without copying, we need 20 extra byte in the buffer (IPv6 packets are 20 byte bigger than IPv4).
pub(crate) const NAT46_OVERHEAD: usize = 20;
/// TURN's data channels have a 4 byte overhead.
pub const DATA_CHANNEL_OVERHEAD: usize = 4;

macro_rules! for_both {
    ($this:ident, |$name:ident| $body:expr) => {
        match $this {
            Self::Ipv4($name) => $body,
            Self::Ipv6($name) => $body,
        }
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Protocol {
    /// Contains either the source or destination port.
    Tcp(u16),
    /// Contains either the source or destination port.
    Udp(u16),
    /// Contains the `identifier` of the ICMP packet.
    Icmp(u16),
}

impl Protocol {
    pub fn same_type(&self, other: &Protocol) -> bool {
        matches!(
            (self, other),
            (Protocol::Tcp(_), Protocol::Tcp(_))
                | (Protocol::Udp(_), Protocol::Udp(_))
                | (Protocol::Icmp(_), Protocol::Icmp(_))
        )
    }

    pub fn value(&self) -> u16 {
        match self {
            Protocol::Tcp(v) => *v,
            Protocol::Udp(v) => *v,
            Protocol::Icmp(v) => *v,
        }
    }

    pub fn with_value(self, value: u16) -> Protocol {
        match self {
            Protocol::Tcp(_) => Protocol::Tcp(value),
            Protocol::Udp(_) => Protocol::Udp(value),
            Protocol::Icmp(_) => Protocol::Icmp(value),
        }
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Layer4Protocol {
    Udp { src: u16, dst: u16 },
    Tcp { src: u16, dst: u16 },
    Icmp { seq: u16, id: u16 },
}

/// A buffer for reading a new [`IpPacket`] from the network.
#[derive(Default)]
pub struct IpPacketBuf {
    inner: Buffer,
}

impl IpPacketBuf {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn buf(&mut self) -> &mut [u8] {
        &mut self.inner[NAT46_OVERHEAD..] // We read packets at an offset so we can convert without copying.
    }
}

#[derive(PartialEq, Clone)]
pub enum IpPacket {
    Ipv4(ConvertibleIpv4Packet),
    Ipv6(ConvertibleIpv6Packet),
}

impl std::fmt::Debug for IpPacket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut dbg = f.debug_struct("Packet");

        dbg.field("src", &self.source())
            .field("dst", &self.destination())
            .field(
                "protocol",
                &self.next_header().keyword_str().unwrap_or("unknown"),
            );

        if let Some(icmp) = self.as_icmpv4() {
            dbg.field("icmp_type", &icmp.icmp_type());
        }

        if let Some(icmp) = self.as_icmpv6() {
            dbg.field("icmp_type", &icmp.icmp_type());
        }

        if let Some(tcp) = self.as_tcp() {
            dbg.field("src_port", &tcp.source_port())
                .field("dst_port", &tcp.destination_port())
                .field("seq", &tcp.sequence_number());

            if tcp.syn() {
                dbg.field("syn", &true);
            }

            if tcp.rst() {
                dbg.field("rst", &true);
            }

            if tcp.fin() {
                dbg.field("fin", &true);
            }
        }

        if let Some(udp) = self.as_udp() {
            dbg.field("src_port", &udp.source_port())
                .field("dst_port", &udp.destination_port());
        }

        dbg.finish()
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct ConvertibleIpv4Packet {
    buf: Buffer,
    start: usize,
    len: usize,
}

impl ConvertibleIpv4Packet {
    pub fn new(ip: IpPacketBuf, len: usize) -> Result<ConvertibleIpv4Packet> {
        let this = Self {
            buf: ip.inner,
            start: NAT46_OVERHEAD,
            len,
        };
        Ipv4Slice::from_slice(this.packet()).context("Invalid IPv4 packet")?;

        Ok(this)
    }

    fn ip_header(&self) -> Ipv4HeaderSlice {
        Ipv4HeaderSlice::from_slice(self.packet()).expect("we checked this during `new`")
    }

    fn ip_header_mut(&mut self) -> Ipv4HeaderSliceMut {
        Ipv4HeaderSliceMut::from_slice(self.packet_mut()).expect("we checked this during `new`")
    }

    pub fn get_source(&self) -> Ipv4Addr {
        self.ip_header().source_addr()
    }

    fn get_destination(&self) -> Ipv4Addr {
        self.ip_header().destination_addr()
    }

    fn consume_to_ipv6(mut self, src: Ipv6Addr, dst: Ipv6Addr) -> Result<ConvertibleIpv6Packet> {
        // `translate_in_place` expects the packet to sit at a 20-byte offset.
        // `self.start` tells us where the packet actually starts, thus we need to pass `self.start - 20` to the function.
        let start_minus_padding = self
            .start
            .checked_sub(NAT46_OVERHEAD)
            .context("Invalid `start`of IP packet in buffer")?;

        let offset = nat46::translate_in_place(
            &mut self.buf[start_minus_padding..(self.start + self.len)],
            src,
            dst,
        )
        .context("NAT46 failed")?;

        // We need to handle 2 cases here:
        // `offset` > NAT46_OVERHEAD
        // `offset` < NAT46_OVERHEAD
        // By casting to an `isize` we can simply compute the _difference_ of the packet length.
        // `offset` points into the buffer we passed to `translate_in_place`.
        // We passed 20 (NAT46_OVERHEAD) bytes more to that function.
        // Thus, 20 - offset tells us the difference in length of the new packet.
        let len_diff = (NAT46_OVERHEAD as isize) - (offset as isize);
        let len = (self.len as isize) + len_diff;

        Ok(ConvertibleIpv6Packet {
            buf: self.buf,
            start: start_minus_padding + offset,
            len: len as usize,
        })
    }

    fn header_length(&self) -> usize {
        (self.ip_header().ihl() * 4) as usize
    }

    pub fn packet(&self) -> &[u8] {
        &self.buf[self.start..(self.start + self.len)]
    }

    fn packet_mut(&mut self) -> &mut [u8] {
        &mut self.buf[self.start..(self.start + self.len)]
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct ConvertibleIpv6Packet {
    buf: Buffer,
    start: usize,
    len: usize,
}

impl ConvertibleIpv6Packet {
    pub fn new(ip: IpPacketBuf, len: usize) -> Result<ConvertibleIpv6Packet> {
        let this = Self {
            buf: ip.inner,
            start: NAT46_OVERHEAD,
            len,
        };

        Ipv6Slice::from_slice(this.packet()).context("Invalid IPv6 packet")?;

        Ok(this)
    }

    fn header(&self) -> Ipv6HeaderSlice {
        Ipv6HeaderSlice::from_slice(self.packet()).expect("We checked this in `new` / `owned`")
    }

    fn header_mut(&mut self) -> Ipv6HeaderSliceMut {
        Ipv6HeaderSliceMut::from_slice(self.packet_mut())
            .expect("We checked this in `new` / `owned`")
    }

    pub fn get_source(&self) -> Ipv6Addr {
        self.header().source_addr()
    }

    fn get_destination(&self) -> Ipv6Addr {
        self.header().destination_addr()
    }

    fn consume_to_ipv4(mut self, src: Ipv4Addr, dst: Ipv4Addr) -> Result<ConvertibleIpv4Packet> {
        nat64::translate_in_place(self.packet_mut(), src, dst).context("NAT64 failed")?;

        Ok(ConvertibleIpv4Packet {
            buf: self.buf,
            start: self.start + 20,
            len: self.len - 20,
        })
    }

    pub fn packet(&self) -> &[u8] {
        &self.buf[self.start..(self.start + self.len)]
    }

    fn packet_mut(&mut self) -> &mut [u8] {
        &mut self.buf[self.start..(self.start + self.len)]
    }
}

pub fn ipv4_embedded(ip: Ipv4Addr) -> Ipv6Addr {
    Ipv6Addr::new(
        0x64,
        0xff9b,
        0x00,
        0x00,
        0x00,
        0x00,
        u16::from_be_bytes([ip.octets()[0], ip.octets()[1]]),
        u16::from_be_bytes([ip.octets()[2], ip.octets()[3]]),
    )
}

pub fn ipv6_translated(ip: Ipv6Addr) -> Option<Ipv4Addr> {
    if ip.segments()[0] != 0x64
        || ip.segments()[1] != 0xff9b
        || ip.segments()[2] != 0
        || ip.segments()[3] != 0
        || ip.segments()[4] != 0
        || ip.segments()[5] != 0
    {
        return None;
    }

    Some(Ipv4Addr::new(
        ip.octets()[12],
        ip.octets()[13],
        ip.octets()[14],
        ip.octets()[15],
    ))
}

impl IpPacket {
    pub fn new(buf: IpPacketBuf, len: usize) -> Result<Self> {
        anyhow::ensure!(len <= MAX_IP_SIZE, "Packet too large (len: {len})");

        Ok(match buf.inner[NAT46_OVERHEAD] >> 4 {
            4 => IpPacket::Ipv4(ConvertibleIpv4Packet::new(buf, len)?),
            6 => IpPacket::Ipv6(ConvertibleIpv6Packet::new(buf, len)?),
            v => bail!("Invalid IP version: {v}"),
        })
    }

    pub(crate) fn consume_to_ipv4(self, src: Ipv4Addr, dst: Ipv4Addr) -> Result<IpPacket> {
        match self {
            IpPacket::Ipv4(pkt) => Ok(IpPacket::Ipv4(pkt)),
            IpPacket::Ipv6(pkt) => Ok(IpPacket::Ipv4(pkt.consume_to_ipv4(src, dst)?)),
        }
    }

    pub(crate) fn consume_to_ipv6(self, src: Ipv6Addr, dst: Ipv6Addr) -> Result<IpPacket> {
        match self {
            IpPacket::Ipv4(pkt) => Ok(IpPacket::Ipv6(pkt.consume_to_ipv6(src, dst)?)),
            IpPacket::Ipv6(pkt) => Ok(IpPacket::Ipv6(pkt)),
        }
    }

    pub fn source(&self) -> IpAddr {
        for_both!(self, |i| i.get_source().into())
    }

    pub fn destination(&self) -> IpAddr {
        for_both!(self, |i| i.get_destination().into())
    }

    pub fn source_protocol(&self) -> Result<Protocol, UnsupportedProtocol> {
        if let Some(p) = self.as_tcp() {
            return Ok(Protocol::Tcp(p.source_port()));
        }

        if let Some(p) = self.as_udp() {
            return Ok(Protocol::Udp(p.source_port()));
        }

        if let Some(p) = self.as_icmpv4() {
            let id = self
                .icmpv4_echo_header()
                .ok_or_else(|| UnsupportedProtocol::UnsupportedIcmpv4Type(p.icmp_type()))?
                .id;

            return Ok(Protocol::Icmp(id));
        }

        if let Some(p) = self.as_icmpv6() {
            let id = self
                .icmpv6_echo_header()
                .ok_or_else(|| UnsupportedProtocol::UnsupportedIcmpv6Type(p.icmp_type()))?
                .id;

            return Ok(Protocol::Icmp(id));
        }

        Err(UnsupportedProtocol::UnsupportedIpPayload(
            self.next_header(),
        ))
    }

    pub fn destination_protocol(&self) -> Result<Protocol, UnsupportedProtocol> {
        if let Some(p) = self.as_tcp() {
            return Ok(Protocol::Tcp(p.destination_port()));
        }

        if let Some(p) = self.as_udp() {
            return Ok(Protocol::Udp(p.destination_port()));
        }

        if let Some(p) = self.as_icmpv4() {
            let id = self
                .icmpv4_echo_header()
                .ok_or_else(|| UnsupportedProtocol::UnsupportedIcmpv4Type(p.icmp_type()))?
                .id;

            return Ok(Protocol::Icmp(id));
        }

        if let Some(p) = self.as_icmpv6() {
            let id = self
                .icmpv6_echo_header()
                .ok_or_else(|| UnsupportedProtocol::UnsupportedIcmpv6Type(p.icmp_type()))?
                .id;

            return Ok(Protocol::Icmp(id));
        }

        Err(UnsupportedProtocol::UnsupportedIpPayload(
            self.next_header(),
        ))
    }

    pub fn set_source_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp_mut() {
            p.set_source_port(v);
        }

        if let Some(mut p) = self.as_udp_mut() {
            p.set_source_port(v);
        }

        self.set_icmp_identifier(v);
    }

    pub fn set_destination_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp_mut() {
            p.set_destination_port(v);
        }

        if let Some(mut p) = self.as_udp_mut() {
            p.set_destination_port(v);
        }

        self.set_icmp_identifier(v);
    }

    fn set_icmp_identifier(&mut self, v: u16) {
        if let Some(mut p) = self.as_icmpv4_mut() {
            p.set_identifier(v);
        }

        if let Some(mut p) = self.as_icmpv6_mut() {
            p.set_identifier(v);
        }
    }

    #[inline]
    pub fn update_checksum(&mut self) {
        // Note: ipv6 doesn't have a checksum.
        self.set_icmpv6_checksum();
        self.set_icmpv4_checksum();
        self.set_udp_checksum();
        self.set_tcp_checksum();
        // Note: Ipv4 checksum should be set after the others,
        // since it's in an upper layer.
        self.set_ipv4_checksum();
    }

    fn set_ipv4_checksum(&mut self) {
        let Self::Ipv4(p) = self else {
            return;
        };

        let checksum = p.ip_header().to_header().calc_header_checksum();
        p.ip_header_mut().set_checksum(checksum);
    }

    fn set_udp_checksum(&mut self) {
        let Some(udp) = self.as_udp() else {
            return;
        };

        let checksum = match &self {
            IpPacket::Ipv4(v4) => udp
                .to_header()
                .calc_checksum_ipv4(&v4.ip_header().to_header(), udp.payload()),
            IpPacket::Ipv6(v6) => udp
                .to_header()
                .calc_checksum_ipv6(&v6.header().to_header(), udp.payload()),
        }
        .expect("size of payload was previously checked to be okay");

        self.as_udp_mut()
            .expect("Developer error: we can only get a UDP checksum if the packet is udp")
            .set_checksum(checksum);
    }

    fn set_tcp_checksum(&mut self) {
        let Some(tcp) = self.as_tcp() else {
            return;
        };

        let checksum = match &self {
            IpPacket::Ipv4(v4) => tcp
                .to_header()
                .calc_checksum_ipv4(&v4.ip_header().to_header(), tcp.payload()),
            IpPacket::Ipv6(v6) => tcp
                .to_header()
                .calc_checksum_ipv6(&v6.header().to_header(), tcp.payload()),
        }
        .expect("size of payload was previously checked to be okay");

        self.as_tcp_mut()
            .expect("Developer error: we can only get a UDP checksum if the packet is udp")
            .set_checksum(checksum);
    }

    pub fn as_udp(&self) -> Option<UdpSlice> {
        if !self.is_udp() {
            return None;
        }

        UdpSlice::from_slice(self.payload()).ok()
    }

    pub fn as_udp_mut(&mut self) -> Option<UdpHeaderSliceMut> {
        if !self.is_udp() {
            return None;
        }

        UdpHeaderSliceMut::from_slice(self.payload_mut()).ok()
    }

    pub fn as_tcp(&self) -> Option<TcpSlice> {
        if !self.is_tcp() {
            return None;
        }

        TcpSlice::from_slice(self.payload()).ok()
    }

    pub fn as_tcp_mut(&mut self) -> Option<TcpHeaderSliceMut> {
        if !self.is_tcp() {
            return None;
        }

        TcpHeaderSliceMut::from_slice(self.payload_mut()).ok()
    }

    fn set_icmpv6_checksum(&mut self) {
        let Some(i) = self.as_icmpv6() else {
            return;
        };

        let IpPacket::Ipv6(p) = &self else {
            return;
        };

        let checksum = i
            .icmp_type()
            .calc_checksum(
                p.get_source().octets(),
                p.get_destination().octets(),
                i.payload(),
            )
            .expect("Payload came from the original packet");

        let Some(mut i) = self.as_icmpv6_mut() else {
            return;
        };

        i.set_checksum(checksum);
    }

    fn set_icmpv4_checksum(&mut self) {
        let Some(i) = self.as_icmpv4() else {
            return;
        };

        let checksum = i.icmp_type().calc_checksum(i.payload());

        let Some(mut i) = self.as_icmpv4_mut() else {
            return;
        };

        i.set_checksum(checksum);
    }

    pub fn as_icmpv4(&self) -> Option<Icmpv4Slice> {
        if !self.is_icmp() {
            return None;
        }

        Icmpv4Slice::from_slice(self.payload()).ok()
    }

    pub fn as_icmpv4_mut(&mut self) -> Option<Icmpv4HeaderSliceMut> {
        if !self.is_icmp() {
            return None;
        }

        Icmpv4HeaderSliceMut::from_slice(self.payload_mut()).ok()
    }

    /// In case the packet is an ICMP unreachable error, parses the unroutable packet from the ICMP payload.
    pub fn icmp_unreachable_destination(&self) -> Result<Option<(FailedPacket, DestUnreachable)>> {
        if let Some(icmpv4) = self.as_icmpv4() {
            let icmp_type = icmpv4.icmp_type();

            // Handle success case early to avoid erroring below.
            if matches!(
                icmp_type,
                Icmpv4Type::EchoReply(_) | Icmpv4Type::EchoRequest(_)
            ) {
                return Ok(None);
            }

            let Icmpv4Type::DestinationUnreachable(error) = icmp_type else {
                bail!("ICMP message is not `DestinationUnreachable` but {icmp_type:?}");
            };

            let (ipv4, _) = LaxIpv4Slice::from_slice(icmpv4.payload())
                .context("Failed to parse payload of ICMPv4 error message as IPv4 packet")?;
            let header = ipv4.header();

            let src = IpAddr::V4(header.source_addr());
            let failed_dst = IpAddr::V4(header.destination_addr());
            let l4_proto = extract_l4_proto(ipv4.payload().payload, header.protocol())
                .context("Failed to extract protocol")?;

            return Ok(Some((
                FailedPacket {
                    src,
                    failed_dst,
                    l4_proto,
                    raw: icmpv4.payload().to_vec(),
                },
                DestUnreachable::V4 {
                    header: error,
                    total_length: header.total_len(),
                },
            )));
        }

        if let Some(icmpv6) = self.as_icmpv6() {
            let icmp_type = icmpv6.icmp_type();

            // Handle success case early to avoid erroring below.
            if matches!(
                icmp_type,
                Icmpv6Type::EchoReply(_) | Icmpv6Type::EchoRequest(_)
            ) {
                return Ok(None);
            }

            #[expect(
                clippy::wildcard_enum_match_arm,
                reason = "We only want to match on these two variants"
            )]
            let dest_unreachable = match icmp_type {
                Icmpv6Type::DestinationUnreachable(error) => DestUnreachable::V6Unreachable(error),
                Icmpv6Type::PacketTooBig { mtu } => DestUnreachable::V6PacketTooBig { mtu },
                other => {
                    bail!(
                        "ICMP message is not `DestinationUnreachable` or `PacketTooBig` but {other:?}"
                    );
                }
            };

            let (ipv6, _) = LaxIpv6Slice::from_slice(icmpv6.payload())
                .context("Failed to parse payload of ICMPv6 error message as IPv6 packet")?;
            let header = ipv6.header();

            let src = IpAddr::V6(header.source_addr());
            let failed_dst = IpAddr::V6(header.destination_addr());
            let l4_proto = extract_l4_proto(ipv6.payload().payload, header.next_header())
                .context("Failed to extract protocol")?;

            return Ok(Some((
                FailedPacket {
                    src,
                    failed_dst,
                    l4_proto,
                    raw: icmpv6.payload().to_vec(),
                },
                dest_unreachable,
            )));
        }

        Ok(None)
    }

    pub fn as_icmpv6(&self) -> Option<Icmpv6Slice> {
        if !self.is_icmpv6() {
            return None;
        }

        Icmpv6Slice::from_slice(self.payload()).ok()
    }

    pub fn as_icmpv6_mut(&mut self) -> Option<Icmpv6EchoHeaderSliceMut> {
        if !self.is_icmpv6() {
            return None;
        }

        Icmpv6EchoHeaderSliceMut::from_slice(self.payload_mut()).ok()
    }

    pub fn as_fz_p2p_control(&self) -> Option<FzP2pControlSlice> {
        if !self.is_fz_p2p_control() {
            return None;
        }

        FzP2pControlSlice::from_slice(self.payload()).ok()
    }

    fn icmpv4_echo_header(&self) -> Option<IcmpEchoHeader> {
        let p = self.as_icmpv4()?;

        use Icmpv4Type::*;
        let icmp_type = p.icmp_type();

        let (EchoReply(header) | EchoRequest(header)) = icmp_type else {
            return None;
        };

        Some(header)
    }

    fn icmpv6_echo_header(&self) -> Option<IcmpEchoHeader> {
        let p = self.as_icmpv6()?;

        use Icmpv6Type::*;
        let icmp_type = p.icmp_type();

        let (EchoReply(header) | EchoRequest(header)) = icmp_type else {
            return None;
        };

        Some(header)
    }

    pub fn translate_destination(
        mut self,
        src_v4: Ipv4Addr,
        src_v6: Ipv6Addr,
        src_proto: Protocol,
        dst: IpAddr,
    ) -> Result<IpPacket> {
        let mut packet = match (&self, dst) {
            (&IpPacket::Ipv4(_), IpAddr::V6(dst)) => self.consume_to_ipv6(src_v6, dst)?,
            (&IpPacket::Ipv6(_), IpAddr::V4(dst)) => self.consume_to_ipv4(src_v4, dst)?,
            _ => {
                self.set_dst(dst);
                self
            }
        };
        packet.set_source_protocol(src_proto.value());

        Ok(packet)
    }

    pub fn translate_source(
        mut self,
        dst_v4: Ipv4Addr,
        dst_v6: Ipv6Addr,
        dst_proto: Protocol,
        src: IpAddr,
    ) -> Result<IpPacket> {
        let mut packet = match (&self, src) {
            (&IpPacket::Ipv4(_), IpAddr::V6(src)) => self.consume_to_ipv6(src, dst_v6)?,
            (&IpPacket::Ipv6(_), IpAddr::V4(src)) => self.consume_to_ipv4(src, dst_v4)?,
            _ => {
                self.set_src(src);
                self
            }
        };
        packet.set_destination_protocol(dst_proto.value());

        Ok(packet)
    }

    #[inline]
    pub fn set_dst(&mut self, dst: IpAddr) {
        match (self, dst) {
            (Self::Ipv4(p), IpAddr::V4(d)) => {
                p.ip_header_mut().set_destination(d.octets());
            }
            (Self::Ipv6(p), IpAddr::V6(d)) => {
                p.header_mut().set_destination(d.octets());
            }
            (Self::Ipv4(_), IpAddr::V6(_)) => {
                debug_assert!(false, "Cannot set an IPv6 address on an IPv4 packet")
            }
            (Self::Ipv6(_), IpAddr::V4(_)) => {
                debug_assert!(false, "Cannot set an IPv4 address on an IPv6 packet")
            }
        }
    }

    #[inline]
    pub fn set_src(&mut self, src: IpAddr) {
        match (self, src) {
            (Self::Ipv4(p), IpAddr::V4(s)) => {
                p.ip_header_mut().set_source(s.octets());
            }
            (Self::Ipv6(p), IpAddr::V6(s)) => {
                p.header_mut().set_source(s.octets());
            }
            (Self::Ipv4(_), IpAddr::V6(_)) => {
                debug_assert!(false, "Cannot set an IPv6 address on an IPv4 packet")
            }
            (Self::Ipv6(_), IpAddr::V4(_)) => {
                debug_assert!(false, "Cannot set an IPv4 address on an IPv6 packet")
            }
        }
    }

    pub fn ipv4_header(&self) -> Option<Ipv4Header> {
        match self {
            Self::Ipv4(p) => Some(p.ip_header().to_header()),
            Self::Ipv6(_) => None,
        }
    }

    pub fn ipv6_header(&self) -> Option<Ipv6Header> {
        match self {
            Self::Ipv4(_) => None,
            Self::Ipv6(p) => Some(p.header().to_header()),
        }
    }

    pub fn next_header(&self) -> IpNumber {
        match self {
            Self::Ipv4(p) => p.ip_header().protocol(),
            Self::Ipv6(p) => p.header().next_header(),
        }
    }

    pub fn is_udp(&self) -> bool {
        self.next_header() == IpNumber::UDP
    }

    pub fn is_tcp(&self) -> bool {
        self.next_header() == IpNumber::TCP
    }

    pub fn is_icmp(&self) -> bool {
        self.next_header() == IpNumber::ICMP
    }

    /// Whether the packet is a Firezone p2p control protocol packet.
    pub fn is_fz_p2p_control(&self) -> bool {
        self.next_header() == fz_p2p_control::IP_NUMBER
            && self.source() == fz_p2p_control::ADDR
            && self.destination() == fz_p2p_control::ADDR
    }

    pub fn is_icmpv6(&self) -> bool {
        self.next_header() == IpNumber::IPV6_ICMP
    }

    fn header_length(&self) -> usize {
        match self {
            IpPacket::Ipv4(v4) => v4.header_length(),
            IpPacket::Ipv6(v6) => v6.header().header_len(),
        }
    }

    fn payload_length(&self) -> u16 {
        match self {
            IpPacket::Ipv4(v4) => v4.ip_header().total_len() - v4.header_length() as u16,
            IpPacket::Ipv6(v6) => v6.header().payload_length(),
        }
    }

    pub fn packet(&self) -> &[u8] {
        match self {
            IpPacket::Ipv4(v4) => v4.packet(),
            IpPacket::Ipv6(v6) => v6.packet(),
        }
    }

    fn packet_mut(&mut self) -> &mut [u8] {
        match self {
            IpPacket::Ipv4(v4) => v4.packet_mut(),
            IpPacket::Ipv6(v6) => v6.packet_mut(),
        }
    }

    pub fn payload(&self) -> &[u8] {
        let start = self.header_length();
        let payload_length = self.payload_length() as usize;

        &self.packet()[start..(start + payload_length)]
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        let start = self.header_length();
        let payload_length = self.payload_length() as usize;

        &mut self.packet_mut()[start..(start + payload_length)]
    }
}

fn extract_l4_proto(payload: &[u8], protocol: IpNumber) -> Result<Layer4Protocol> {
    let proto = match protocol {
        IpNumber::UDP => {
            let udp =
                UdpHeaderSlice::from_slice(payload).context("Failed to parse payload as UDP")?;

            Layer4Protocol::Udp {
                src: udp.source_port(),
                dst: udp.destination_port(),
            }
        }
        IpNumber::TCP => {
            let tcp =
                TcpHeaderSlice::from_slice(payload).context("Failed to parse payload as TCP")?;

            Layer4Protocol::Tcp {
                src: tcp.source_port(),
                dst: tcp.destination_port(),
            }
        }
        IpNumber::ICMP => {
            let icmp_type = Icmpv4Slice::from_slice(payload)
                .context("Failed to parse payload as ICMPv4")?
                .header()
                .icmp_type;

            let Icmpv4Type::EchoRequest(echo_header) = icmp_type else {
                bail!("Original packet was not any ICMP echo request but {icmp_type:?}")
            };

            Layer4Protocol::Icmp {
                seq: echo_header.seq,
                id: echo_header.id,
            }
        }
        IpNumber::IPV6_ICMP => {
            let icmp_type = Icmpv6Slice::from_slice(payload)
                .context("Failed to parse payload as ICMPv6")?
                .header()
                .icmp_type;

            let Icmpv6Type::EchoRequest(echo_header) = icmp_type else {
                bail!("Original packet was not any ICMP echo request but {icmp_type:?}")
            };

            Layer4Protocol::Icmp {
                seq: echo_header.seq,
                id: echo_header.id,
            }
        }
        other => {
            bail!("Unsupported protocol: {:?}", other.keyword_str())
        }
    };
    Ok(proto)
}

impl From<ConvertibleIpv4Packet> for IpPacket {
    fn from(value: ConvertibleIpv4Packet) -> Self {
        Self::Ipv4(value)
    }
}

impl From<ConvertibleIpv6Packet> for IpPacket {
    fn from(value: ConvertibleIpv6Packet) -> Self {
        Self::Ipv6(value)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum UnsupportedProtocol {
    #[error("Unsupported IP protocol: {0:?}")]
    UnsupportedIpPayload(IpNumber),
    #[error("Unsupported ICMPv4 type: {0:?}")]
    UnsupportedIcmpv4Type(Icmpv4Type),
    #[error("Unsupported ICMPv6 type: {0:?}")]
    UnsupportedIcmpv6Type(Icmpv6Type),
}

#[derive(Debug, thiserror::Error)]
#[error("Packet cannot be translated as part of NAT64/46")]
pub struct ImpossibleTranslation;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn udp_packet_payload() {
        let udp_packet = crate::make::udp_packet(
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::LOCALHOST,
            0,
            0,
            b"foobar".to_vec(),
        )
        .unwrap();

        let ip_payload = udp_packet.payload();
        let udp_payload = &ip_payload[etherparse::UdpHeader::LEN..];

        assert_eq!(udp_payload, b"foobar");
    }
}
