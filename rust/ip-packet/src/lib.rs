pub mod make;

mod icmpv4_header_slice_mut;
mod icmpv6_header_slice_mut;
mod ipv4_header_slice_mut;
mod ipv6_header_slice_mut;
mod nat46;
mod nat64;
#[cfg(feature = "proptest")]
pub mod proptest;
mod slice_utils;
mod tcp_header_slice_mut;
mod udp_header_slice_mut;

pub use etherparse::*;

#[cfg(all(test, feature = "proptest"))]
mod proptests;

use icmpv4_header_slice_mut::Icmpv4HeaderSliceMut;
use icmpv6_header_slice_mut::Icmpv6EchoHeaderSliceMut;
use ipv4_header_slice_mut::Ipv4HeaderSliceMut;
use ipv6_header_slice_mut::Ipv6HeaderSliceMut;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    ops::{Deref, DerefMut},
};
use tcp_header_slice_mut::TcpHeaderSliceMut;
use udp_header_slice_mut::UdpHeaderSliceMut;

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

#[derive(PartialEq, Clone)]
pub enum IpPacket<'a> {
    Ipv4(ConvertibleIpv4Packet<'a>),
    Ipv6(ConvertibleIpv6Packet<'a>),
}

impl<'a> std::fmt::Debug for IpPacket<'a> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Ipv4(arg0) => arg0.ip_header().to_header().fmt(f),
            Self::Ipv6(arg0) => arg0.header().to_header().fmt(f),
        }
    }
}

#[derive(Debug, PartialEq)]
enum MaybeOwned<'a> {
    RefMut(&'a mut [u8]),
    Owned(Vec<u8>),
}

impl<'a> MaybeOwned<'a> {
    fn remove_from_head(self, bytes: usize) -> MaybeOwned<'a> {
        match self {
            MaybeOwned::RefMut(ref_mut) => MaybeOwned::RefMut(&mut ref_mut[bytes..]),
            MaybeOwned::Owned(mut owned) => {
                owned.drain(0..bytes);
                MaybeOwned::Owned(owned)
            }
        }
    }
}

impl<'a> Clone for MaybeOwned<'a> {
    fn clone(&self) -> Self {
        match self {
            Self::RefMut(i) => Self::Owned(i.to_vec()),
            Self::Owned(i) => Self::Owned(i.clone()),
        }
    }
}

impl<'a> Deref for MaybeOwned<'a> {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        match self {
            MaybeOwned::RefMut(ref_mut) => ref_mut,
            MaybeOwned::Owned(owned) => owned,
        }
    }
}

impl<'a> DerefMut for MaybeOwned<'a> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        match self {
            MaybeOwned::RefMut(ref_mut) => ref_mut,
            MaybeOwned::Owned(owned) => owned,
        }
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct ConvertibleIpv4Packet<'a> {
    buf: MaybeOwned<'a>,
}

impl<'a> ConvertibleIpv4Packet<'a> {
    pub fn new(buf: &'a mut [u8]) -> Option<ConvertibleIpv4Packet<'a>> {
        Ipv4HeaderSlice::from_slice(&buf[20..]).ok()?;
        Some(Self {
            buf: MaybeOwned::RefMut(buf),
        })
    }

    fn owned(buf: Vec<u8>) -> Option<ConvertibleIpv4Packet<'a>> {
        Ipv4HeaderSlice::from_slice(&buf[20..]).ok()?;
        Some(Self {
            buf: MaybeOwned::Owned(buf),
        })
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

    fn consume_to_ipv6(
        mut self,
        src: Ipv6Addr,
        dst: Ipv6Addr,
    ) -> Option<ConvertibleIpv6Packet<'a>> {
        let offset = nat46::translate_in_place(&mut self.buf, src, dst)
            .inspect_err(|e| tracing::trace!("NAT64 failed: {e:#}"))
            .ok()?;
        let buf = self.buf.remove_from_head(offset);

        Some(ConvertibleIpv6Packet { buf })
    }

    fn header_length(&self) -> usize {
        (self.ip_header().ihl() * 4) as usize
    }

    pub fn packet(&self) -> &[u8] {
        &self.buf[20..]
    }

    fn packet_mut(&mut self) -> &mut [u8] {
        &mut self.buf[20..]
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct ConvertibleIpv6Packet<'a> {
    buf: MaybeOwned<'a>,
}

impl<'a> ConvertibleIpv6Packet<'a> {
    pub fn new(buf: &'a mut [u8]) -> Option<ConvertibleIpv6Packet<'a>> {
        Ipv6HeaderSlice::from_slice(buf).ok()?;

        Some(Self {
            buf: MaybeOwned::RefMut(buf),
        })
    }

    fn owned(buf: Vec<u8>) -> Option<ConvertibleIpv6Packet<'a>> {
        Ipv6HeaderSlice::from_slice(&buf).ok()?;

        Some(Self {
            buf: MaybeOwned::Owned(buf),
        })
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

    fn consume_to_ipv4(
        mut self,
        src: Ipv4Addr,
        dst: Ipv4Addr,
    ) -> Option<ConvertibleIpv4Packet<'a>> {
        nat64::translate_in_place(&mut self.buf, src, dst)
            .inspect_err(|e| tracing::trace!("NAT64 failed: {e:#}"))
            .ok()?;

        Some(ConvertibleIpv4Packet { buf: self.buf })
    }

    pub fn packet(&self) -> &[u8] {
        &self.buf
    }

    fn packet_mut(&mut self) -> &mut [u8] {
        &mut self.buf
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

impl<'a> IpPacket<'a> {
    // TODO: this API is a bit akward, since you have to pass the extra prepended 20 bytes
    pub fn new(buf: &'a mut [u8]) -> Option<Self> {
        match buf[20] >> 4 {
            4 => Some(IpPacket::Ipv4(ConvertibleIpv4Packet::new(buf)?)),
            6 => Some(IpPacket::Ipv6(ConvertibleIpv6Packet::new(&mut buf[20..])?)),
            _ => None,
        }
    }

    pub(crate) fn owned(mut data: Vec<u8>) -> Option<IpPacket<'static>> {
        let packet = match data[20] >> 4 {
            4 => ConvertibleIpv4Packet::owned(data)?.into(),
            6 => {
                data.drain(0..20);
                ConvertibleIpv6Packet::owned(data)?.into()
            }
            _ => return None,
        };

        Some(packet)
    }

    pub fn to_owned(&self) -> IpPacket<'static> {
        match self {
            IpPacket::Ipv4(i) => IpPacket::Ipv4(ConvertibleIpv4Packet {
                buf: MaybeOwned::Owned(i.buf.to_vec()),
            }),
            IpPacket::Ipv6(i) => IpPacket::Ipv6(ConvertibleIpv6Packet {
                buf: MaybeOwned::Owned(i.buf.to_vec()),
            }),
        }
    }

    pub(crate) fn consume_to_ipv4(self, src: Ipv4Addr, dst: Ipv4Addr) -> Option<IpPacket<'a>> {
        match self {
            IpPacket::Ipv4(pkt) => Some(IpPacket::Ipv4(pkt)),
            IpPacket::Ipv6(pkt) => Some(IpPacket::Ipv4(pkt.consume_to_ipv4(src, dst)?)),
        }
    }

    pub(crate) fn consume_to_ipv6(self, src: Ipv6Addr, dst: Ipv6Addr) -> Option<IpPacket<'a>> {
        match self {
            IpPacket::Ipv4(pkt) => Some(IpPacket::Ipv6(pkt.consume_to_ipv6(src, dst)?)),
            IpPacket::Ipv6(pkt) => Some(IpPacket::Ipv6(pkt)),
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
    ) -> Option<IpPacket<'a>> {
        let mut packet = match (&self, dst) {
            (&IpPacket::Ipv4(_), IpAddr::V6(dst)) => self.consume_to_ipv6(src_v6, dst)?,
            (&IpPacket::Ipv6(_), IpAddr::V4(dst)) => self.consume_to_ipv4(src_v4, dst)?,
            _ => {
                self.set_dst(dst);
                self
            }
        };
        packet.set_source_protocol(src_proto.value());

        Some(packet)
    }

    pub fn translate_source(
        mut self,
        dst_v4: Ipv4Addr,
        dst_v6: Ipv6Addr,
        dst_proto: Protocol,
        src: IpAddr,
    ) -> Option<IpPacket<'a>> {
        let mut packet = match (&self, src) {
            (&IpPacket::Ipv4(_), IpAddr::V6(src)) => self.consume_to_ipv6(src, dst_v6)?,
            (&IpPacket::Ipv6(_), IpAddr::V4(src)) => self.consume_to_ipv4(src, dst_v4)?,
            _ => {
                self.set_src(src);
                self
            }
        };
        packet.set_destination_protocol(dst_proto.value());

        Some(packet)
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
            Self::Ipv4(p) => Some(
                Ipv4HeaderSlice::from_slice(p.packet())
                    .expect("Should be a valid packet")
                    .to_header(),
            ),
            Self::Ipv6(_) => None,
        }
    }

    pub fn ipv6_header(&self) -> Option<Ipv6Header> {
        match self {
            Self::Ipv4(_) => None,
            Self::Ipv6(p) => Some(
                Ipv6HeaderSlice::from_slice(p.packet())
                    .expect("Should be a valid packet")
                    .to_header(),
            ),
        }
    }

    fn next_header(&self) -> IpNumber {
        match self {
            Self::Ipv4(p) => p.ip_header().protocol(),
            Self::Ipv6(p) => p.header().next_header(),
        }
    }

    fn is_udp(&self) -> bool {
        self.next_header() == IpNumber::UDP
    }

    fn is_tcp(&self) -> bool {
        self.next_header() == IpNumber::TCP
    }

    pub fn is_icmp(&self) -> bool {
        self.next_header() == IpNumber::ICMP
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

    fn payload(&self) -> &[u8] {
        let start = self.header_length();

        &self.packet()[start..]
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        let start = self.header_length();

        &mut self.packet_mut()[start..]
    }
}

impl<'a> From<ConvertibleIpv4Packet<'a>> for IpPacket<'a> {
    fn from(value: ConvertibleIpv4Packet<'a>) -> Self {
        Self::Ipv4(value)
    }
}

impl<'a> From<ConvertibleIpv6Packet<'a>> for IpPacket<'a> {
    fn from(value: ConvertibleIpv6Packet<'a>) -> Self {
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
