pub mod make;

mod ipv4_header_slice_mut;
mod ipv6_header_slice_mut;
mod nat46;
mod nat64;
#[cfg(feature = "proptest")]
pub mod proptest;
mod slice_utils;

pub use pnet_packet::*;

#[cfg(all(test, feature = "proptest"))]
mod proptests;

use etherparse::{
    IcmpEchoHeader, Icmpv4Slice, Icmpv4Type, Icmpv6Slice, Icmpv6Type, IpNumber, Ipv4Header,
    Ipv4HeaderSlice, Ipv6Header, Ipv6HeaderSlice, TcpSlice, UdpSlice,
};
use ipv4_header_slice_mut::Ipv4HeaderSliceMut;
use ipv6_header_slice_mut::Ipv6HeaderSliceMut;
use pnet_packet::{
    icmp::{
        echo_reply::MutableEchoReplyPacket, echo_request::MutableEchoRequestPacket, IcmpTypes,
        MutableIcmpPacket,
    },
    icmpv6::{Icmpv6Types, MutableIcmpv6Packet},
    tcp::MutableTcpPacket,
    udp::MutableUdpPacket,
};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    ops::{Deref, DerefMut},
};

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

#[derive(Debug, PartialEq)]
pub enum IcmpPacket<'a> {
    Ipv4(Icmpv4Slice<'a>),
    Ipv6(Icmpv6Slice<'a>),
}

impl<'a> IcmpPacket<'a> {
    pub fn icmp_type(&self) -> IcmpType {
        match self {
            IcmpPacket::Ipv4(v4) => IcmpType::V4(v4.icmp_type()),
            IcmpPacket::Ipv6(v6) => IcmpType::V6(v6.icmp_type()),
        }
    }

    pub fn identifier(&self) -> Option<u16> {
        Some(self.echo_request_header().or(self.echo_reply_header())?.id)
    }

    pub fn sequence(&self) -> Option<u16> {
        Some(self.echo_request_header().or(self.echo_reply_header())?.seq)
    }

    pub fn payload(&self) -> &[u8] {
        match self {
            IcmpPacket::Ipv4(v4) => v4.payload(),
            IcmpPacket::Ipv6(v6) => v6.payload(),
        }
    }

    pub fn echo_request_header(&self) -> Option<IcmpEchoHeader> {
        #[allow(
            clippy::wildcard_enum_match_arm,
            reason = "We won't ever need to use other ICMP types here."
        )]
        match self {
            IcmpPacket::Ipv4(v4) => match v4.header().icmp_type {
                Icmpv4Type::EchoRequest(echo) => Some(echo),
                _ => None,
            },
            IcmpPacket::Ipv6(v6) => match v6.header().icmp_type {
                Icmpv6Type::EchoRequest(echo) => Some(echo),
                _ => None,
            },
        }
    }

    pub fn echo_reply_header(&self) -> Option<IcmpEchoHeader> {
        #[allow(
            clippy::wildcard_enum_match_arm,
            reason = "We won't ever need to use other ICMP types here."
        )]
        match self {
            IcmpPacket::Ipv4(v4) => match v4.header().icmp_type {
                Icmpv4Type::EchoReply(echo) => Some(echo),
                _ => None,
            },
            IcmpPacket::Ipv6(v6) => match v6.header().icmp_type {
                Icmpv6Type::EchoReply(echo) => Some(echo),
                _ => None,
            },
        }
    }
}

pub enum IcmpType {
    V4(Icmpv4Type),
    V6(Icmpv6Type),
}

#[derive(Debug, PartialEq, Clone)]
pub enum IpPacket<'a> {
    Ipv4(ConvertibleIpv4Packet<'a>),
    Ipv6(ConvertibleIpv6Packet<'a>),
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
        // TODO: Make `_unchecked` variant public upstream.
        Ipv4HeaderSlice::from_slice(&self.buf[20..]).expect("we checked this during `new`")
    }

    fn ip_header_mut(&mut self) -> Ipv4HeaderSliceMut {
        // Safety: We checked this in `new` / `owned`.
        unsafe { Ipv4HeaderSliceMut::from_slice_unchecked(&mut self.buf[20..]) }
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
}

impl<'a> Packet for ConvertibleIpv4Packet<'a> {
    fn packet(&self) -> &[u8] {
        &self.buf[20..]
    }

    fn payload(&self) -> &[u8] {
        &self.buf[(self.header_length() + 20)..]
    }
}

impl<'a> MutablePacket for ConvertibleIpv4Packet<'a> {
    fn packet_mut(&mut self) -> &mut [u8] {
        &mut self.buf[20..]
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        let header_len = self.header_length();
        &mut self.buf[(header_len + 20)..]
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
        // FIXME: Make the `_unchecked` variant public upstream.
        Ipv6HeaderSlice::from_slice(&self.buf).expect("We checked this in `new` / `owned`")
    }

    fn header_mut(&mut self) -> Ipv6HeaderSliceMut {
        // Safety: We checked this in `new` / `owned`.
        unsafe { Ipv6HeaderSliceMut::from_slice_unchecked(&mut self.buf) }
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
}

impl<'a> Packet for ConvertibleIpv6Packet<'a> {
    fn packet(&self) -> &[u8] {
        &self.buf
    }

    fn payload(&self) -> &[u8] {
        &self.buf[Ipv6Header::LEN..]
    }
}

impl<'a> MutablePacket for ConvertibleIpv6Packet<'a> {
    fn packet_mut(&mut self) -> &mut [u8] {
        &mut self.buf
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        &mut self.buf[Ipv6Header::LEN..]
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

        if let Some(p) = self.as_icmp() {
            let id = p.identifier().ok_or_else(|| match p.icmp_type() {
                IcmpType::V4(v4) => UnsupportedProtocol::UnsupportedIcmpv4Type(v4),
                IcmpType::V6(v6) => UnsupportedProtocol::UnsupportedIcmpv6Type(v6),
            })?;

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

        if let Some(p) = self.as_icmp() {
            let id = p.identifier().ok_or_else(|| match p.icmp_type() {
                IcmpType::V4(v4) => UnsupportedProtocol::UnsupportedIcmpv4Type(v4),
                IcmpType::V6(v6) => UnsupportedProtocol::UnsupportedIcmpv6Type(v6),
            })?;

            return Ok(Protocol::Icmp(id));
        }

        Err(UnsupportedProtocol::UnsupportedIpPayload(
            self.next_header(),
        ))
    }

    pub fn set_source_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp_mut() {
            p.set_source(v);
        }

        if let Some(mut p) = self.as_udp_mut() {
            p.set_source(v);
        }

        self.set_icmp_identifier(v);
    }

    pub fn set_destination_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp_mut() {
            p.set_destination(v);
        }

        if let Some(mut p) = self.as_udp_mut() {
            p.set_destination(v);
        }

        self.set_icmp_identifier(v);
    }

    fn set_icmp_identifier(&mut self, v: u16) {
        if let Some(mut p) = self.as_icmp_mut() {
            if p.get_icmp_type() == IcmpTypes::EchoReply {
                let Some(mut echo_reply) = MutableEchoReplyPacket::new(p.packet_mut()) else {
                    return;
                };
                echo_reply.set_identifier(v)
            }

            if p.get_icmp_type() == IcmpTypes::EchoRequest {
                let Some(mut echo_request) = MutableEchoRequestPacket::new(p.packet_mut()) else {
                    return;
                };
                echo_request.set_identifier(v);
            }
        }

        if let Some(mut p) = self.as_icmpv6() {
            if p.get_icmpv6_type() == Icmpv6Types::EchoReply {
                let Some(mut echo_reply) =
                    icmpv6::echo_reply::MutableEchoReplyPacket::new(p.packet_mut())
                else {
                    return;
                };
                echo_reply.set_identifier(v)
            }

            if p.get_icmpv6_type() == Icmpv6Types::EchoRequest {
                let Some(mut echo_request) =
                    icmpv6::echo_request::MutableEchoRequestPacket::new(p.packet_mut())
                else {
                    return;
                };
                echo_request.set_identifier(v);
            }
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
        self.is_udp()
            .then(|| UdpSlice::from_slice(self.payload()).ok())
            .flatten()
    }

    pub fn as_udp_mut(&mut self) -> Option<MutableUdpPacket> {
        self.is_udp()
            .then(|| MutableUdpPacket::new(self.payload_mut()))
            .flatten()
    }

    pub fn as_tcp(&self) -> Option<TcpSlice> {
        self.is_tcp()
            .then(|| TcpSlice::from_slice(self.payload()).ok())
            .flatten()
    }

    pub fn as_tcp_mut(&mut self) -> Option<MutableTcpPacket> {
        self.is_tcp()
            .then(|| MutableTcpPacket::new(self.payload_mut()))
            .flatten()
    }

    pub fn is_icmp_v4_or_v6(&self) -> bool {
        match self {
            IpPacket::Ipv4(v4) => v4.ip_header().protocol() == IpNumber::ICMP,
            IpPacket::Ipv6(v6) => v6.header().next_header() == IpNumber::IPV6_ICMP,
        }
    }

    fn set_icmpv6_checksum(&mut self) {
        let (src_addr, dst_addr) = match self {
            IpPacket::Ipv4(_) => return,
            IpPacket::Ipv6(p) => (p.get_source(), p.get_destination()),
        };
        if let Some(mut pkt) = self.as_icmpv6() {
            let checksum = icmpv6::checksum(&pkt.to_immutable(), &src_addr, &dst_addr);
            pkt.set_checksum(checksum);
        }
    }

    fn set_icmpv4_checksum(&mut self) {
        if let Some(mut pkt) = self.as_icmp_mut() {
            let checksum = icmp::checksum(&pkt.to_immutable());
            pkt.set_checksum(checksum);
        }
    }

    pub fn as_icmp(&self) -> Option<IcmpPacket> {
        match self {
            Self::Ipv4(v4) if self.is_icmp() => Some(IcmpPacket::Ipv4(
                Icmpv4Slice::from_slice(v4.payload()).ok()?,
            )),
            Self::Ipv6(v6) if self.is_icmpv6() => Some(IcmpPacket::Ipv6(
                Icmpv6Slice::from_slice(v6.payload()).ok()?,
            )),
            Self::Ipv4(_) | Self::Ipv6(_) => None,
        }
    }

    pub fn as_icmp_mut(&mut self) -> Option<MutableIcmpPacket> {
        self.is_icmp()
            .then(|| MutableIcmpPacket::new(self.payload_mut()))
            .flatten()
    }

    fn as_icmpv6(&mut self) -> Option<MutableIcmpv6Packet> {
        self.is_icmpv6()
            .then(|| MutableIcmpv6Packet::new(self.payload_mut()))
            .flatten()
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

    fn is_icmp(&self) -> bool {
        self.next_header() == IpNumber::ICMP
    }

    fn is_icmpv6(&self) -> bool {
        self.next_header() == IpNumber::IPV6_ICMP
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

impl pnet_packet::Packet for IpPacket<'_> {
    fn packet(&self) -> &[u8] {
        for_both!(self, |i| i.packet())
    }

    fn payload(&self) -> &[u8] {
        for_both!(self, |i| i.payload())
    }
}

impl pnet_packet::MutablePacket for IpPacket<'_> {
    fn packet_mut(&mut self) -> &mut [u8] {
        for_both!(self, |i| i.packet_mut())
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        for_both!(self, |i| i.payload_mut())
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
