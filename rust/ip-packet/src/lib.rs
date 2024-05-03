pub mod make;

pub use pnet_packet::*;

use pnet_packet::{
    icmpv6::MutableIcmpv6Packet,
    ip::{IpNextHeaderProtocol, IpNextHeaderProtocols},
    ipv4::{Ipv4Packet, MutableIpv4Packet},
    ipv6::{Ipv6Packet, MutableIpv6Packet},
    tcp::{MutableTcpPacket, TcpPacket},
    udp::{MutableUdpPacket, UdpPacket},
};
use std::net::IpAddr;

macro_rules! for_both {
    ($this:ident, |$name:ident| $body:expr) => {
        match $this {
            Self::Ipv4($name) => $body,
            Self::Ipv6($name) => $body,
        }
    };
}

// no std::mem::swap? no problem
macro_rules! swap_src_dst {
    ($p:expr) => {
        let src = $p.get_source();
        let dst = $p.get_destination();
        $p.set_source(dst);
        $p.set_destination(src);
    };
}

#[derive(Debug, PartialEq)]
pub enum IpPacket<'a> {
    Ipv4(Ipv4Packet<'a>),
    Ipv6(Ipv6Packet<'a>),
}

#[derive(Debug, PartialEq)]
pub enum MutableIpPacket<'a> {
    Ipv4(MutableIpv4Packet<'a>),
    Ipv6(MutableIpv6Packet<'a>),
}

impl<'a> MutableIpPacket<'a> {
    pub fn new(buf: &'a mut [u8]) -> Option<Self> {
        match buf[0] >> 4 {
            4 => Some(MutableIpPacket::Ipv4(MutableIpv4Packet::new(buf)?)),
            6 => Some(MutableIpPacket::Ipv6(MutableIpv6Packet::new(buf)?)),
            _ => None,
        }
    }

    pub fn owned(data: Vec<u8>) -> Option<MutableIpPacket<'static>> {
        let packet = match data[0] >> 4 {
            4 => MutableIpv4Packet::owned(data)?.into(),
            6 => MutableIpv6Packet::owned(data)?.into(),
            _ => return None,
        };

        Some(packet)
    }

    pub fn to_owned(&self) -> MutableIpPacket<'static> {
        match self {
            MutableIpPacket::Ipv4(i) => MutableIpv4Packet::owned(i.packet().to_vec())
                .expect("owned packet should still be valid")
                .into(),
            MutableIpPacket::Ipv6(i) => MutableIpv6Packet::owned(i.packet().to_vec())
                .expect("owned packet should still be valid")
                .into(),
        }
    }

    pub fn to_immutable(&self) -> IpPacket {
        for_both!(self, |i| i.to_immutable().into())
    }

    pub fn source(&self) -> IpAddr {
        for_both!(self, |i| i.get_source().into())
    }

    pub fn destination(&self) -> IpAddr {
        for_both!(self, |i| i.get_destination().into())
    }

    #[inline]
    pub fn update_checksum(&mut self) {
        // Note: neither ipv6 nor icmp have a checksum.
        self.set_icmpv6_checksum();
        self.set_udp_checksum();
        self.set_tcp_checksum();
        // Note: Ipv4 checksum should be set after the others,
        // since it's in an upper layer.
        self.set_ipv4_checksum();
    }

    pub fn set_ipv4_checksum(&mut self) {
        if let Self::Ipv4(p) = self {
            p.set_checksum(ipv4::checksum(&p.to_immutable()));
        }
    }

    fn set_udp_checksum(&mut self) {
        let checksum = if let Some(p) = self.as_immutable_udp() {
            self.to_immutable().udp_checksum(&p.to_immutable())
        } else {
            return;
        };

        self.as_udp()
            .expect("Developer error: we can only get a UDP checksum if the packet is udp")
            .set_checksum(checksum);
    }

    fn set_tcp_checksum(&mut self) {
        let checksum = if let Some(p) = self.as_immutable_tcp() {
            self.to_immutable().tcp_checksum(&p.to_immutable())
        } else {
            return;
        };

        self.as_tcp()
            .expect("Developer error: we can only get a TCP checksum if the packet is tcp")
            .set_checksum(checksum);
    }

    pub fn into_immutable(self) -> IpPacket<'a> {
        match self {
            Self::Ipv4(p) => p.consume_to_immutable().into(),
            Self::Ipv6(p) => p.consume_to_immutable().into(),
        }
    }

    pub fn as_immutable(&self) -> IpPacket<'_> {
        match self {
            Self::Ipv4(p) => IpPacket::Ipv4(p.to_immutable()),
            Self::Ipv6(p) => IpPacket::Ipv6(p.to_immutable()),
        }
    }

    pub fn as_udp(&mut self) -> Option<MutableUdpPacket> {
        self.to_immutable()
            .is_udp()
            .then(|| MutableUdpPacket::new(self.payload_mut()))
            .flatten()
    }

    pub fn as_tcp(&mut self) -> Option<MutableTcpPacket> {
        self.to_immutable()
            .is_tcp()
            .then(|| MutableTcpPacket::new(self.payload_mut()))
            .flatten()
    }

    fn set_icmpv6_checksum(&mut self) {
        let (src_addr, dst_addr) = match self {
            MutableIpPacket::Ipv4(_) => return,
            MutableIpPacket::Ipv6(p) => (p.get_source(), p.get_destination()),
        };
        if let Some(mut pkt) = self.as_icmpv6() {
            let checksum = icmpv6::checksum(&pkt.to_immutable(), &src_addr, &dst_addr);
            pkt.set_checksum(checksum);
        }
    }

    fn as_icmpv6(&mut self) -> Option<MutableIcmpv6Packet> {
        self.to_immutable()
            .is_icmpv6()
            .then(|| MutableIcmpv6Packet::new(self.payload_mut()))
            .flatten()
    }

    pub fn as_immutable_udp(&self) -> Option<UdpPacket> {
        self.to_immutable()
            .is_udp()
            .then(|| UdpPacket::new(self.payload()))
            .flatten()
    }

    pub fn as_immutable_tcp(&self) -> Option<TcpPacket> {
        self.to_immutable()
            .is_tcp()
            .then(|| TcpPacket::new(self.payload()))
            .flatten()
    }

    pub fn swap_src_dst(&mut self) {
        match self {
            Self::Ipv4(p) => {
                swap_src_dst!(p);
            }
            Self::Ipv6(p) => {
                swap_src_dst!(p);
            }
        }
    }

    #[inline]
    pub fn set_dst(&mut self, dst: IpAddr) {
        match (self, dst) {
            (Self::Ipv4(p), IpAddr::V4(d)) => p.set_destination(d),
            (Self::Ipv6(p), IpAddr::V6(d)) => p.set_destination(d),
            _ => {}
        }
    }

    #[inline]
    pub fn set_src(&mut self, src: IpAddr) {
        match (self, src) {
            (Self::Ipv4(p), IpAddr::V4(s)) => p.set_source(s),
            (Self::Ipv6(p), IpAddr::V6(s)) => p.set_source(s),
            _ => {}
        }
    }
}

impl<'a> IpPacket<'a> {
    pub fn new(buf: &'a [u8]) -> Option<Self> {
        match buf[0] >> 4 {
            4 => Some(IpPacket::Ipv4(Ipv4Packet::new(buf)?)),
            6 => Some(IpPacket::Ipv6(Ipv6Packet::new(buf)?)),
            _ => None,
        }
    }

    pub fn to_owned(&self) -> IpPacket<'static> {
        match self {
            IpPacket::Ipv4(i) => Ipv4Packet::owned(i.packet().to_vec())
                .expect("owned packet should still be valid")
                .into(),
            IpPacket::Ipv6(i) => Ipv6Packet::owned(i.packet().to_vec())
                .expect("owned packet should still be valid")
                .into(),
        }
    }

    pub fn source(&self) -> IpAddr {
        for_both!(self, |i| i.get_source().into())
    }

    pub fn destination(&self) -> IpAddr {
        for_both!(self, |i| i.get_destination().into())
    }

    pub fn udp_payload(&self) -> &[u8] {
        debug_assert_eq!(
            match self {
                IpPacket::Ipv4(i) => i.get_next_level_protocol(),
                IpPacket::Ipv6(i) => i.get_next_header(),
            },
            IpNextHeaderProtocols::Udp
        );

        for_both!(self, |i| &i.payload()[8..])
    }

    pub fn owned(data: Vec<u8>) -> Option<IpPacket<'static>> {
        let packet = match data[0] >> 4 {
            4 => Ipv4Packet::owned(data)?.into(),
            6 => Ipv6Packet::owned(data)?.into(),
            _ => return None,
        };

        Some(packet)
    }

    pub fn is_icmpv6(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Icmpv6
    }

    pub fn next_header(&self) -> IpNextHeaderProtocol {
        match self {
            Self::Ipv4(p) => p.get_next_level_protocol(),
            Self::Ipv6(p) => p.get_next_header(),
        }
    }

    fn is_udp(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Udp
    }

    fn is_tcp(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Tcp
    }

    pub fn as_udp(&self) -> Option<UdpPacket> {
        self.is_udp()
            .then(|| UdpPacket::new(self.payload()))
            .flatten()
    }

    pub fn as_tcp(&self) -> Option<TcpPacket> {
        self.is_tcp()
            .then(|| TcpPacket::new(self.payload()))
            .flatten()
    }

    pub fn udp_checksum(&self, dgm: &UdpPacket<'_>) -> u16 {
        match self {
            Self::Ipv4(p) => udp::ipv4_checksum(dgm, &p.get_source(), &p.get_destination()),
            Self::Ipv6(p) => udp::ipv6_checksum(dgm, &p.get_source(), &p.get_destination()),
        }
    }

    fn tcp_checksum(&self, pkt: &TcpPacket<'_>) -> u16 {
        match self {
            Self::Ipv4(p) => tcp::ipv4_checksum(pkt, &p.get_source(), &p.get_destination()),
            Self::Ipv6(p) => tcp::ipv6_checksum(pkt, &p.get_source(), &p.get_destination()),
        }
    }
}

impl<'a> From<Ipv4Packet<'a>> for IpPacket<'a> {
    fn from(value: Ipv4Packet<'a>) -> Self {
        Self::Ipv4(value)
    }
}

impl<'a> From<Ipv6Packet<'a>> for IpPacket<'a> {
    fn from(value: Ipv6Packet<'a>) -> Self {
        Self::Ipv6(value)
    }
}

impl<'a> From<MutableIpv4Packet<'a>> for MutableIpPacket<'a> {
    fn from(value: MutableIpv4Packet<'a>) -> Self {
        Self::Ipv4(value)
    }
}

impl<'a> From<MutableIpv6Packet<'a>> for MutableIpPacket<'a> {
    fn from(value: MutableIpv6Packet<'a>) -> Self {
        Self::Ipv6(value)
    }
}

impl pnet_packet::Packet for MutableIpPacket<'_> {
    fn packet(&self) -> &[u8] {
        for_both!(self, |i| i.packet())
    }

    fn payload(&self) -> &[u8] {
        for_both!(self, |i| i.payload())
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

impl pnet_packet::MutablePacket for MutableIpPacket<'_> {
    fn packet_mut(&mut self) -> &mut [u8] {
        for_both!(self, |i| i.packet_mut())
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        for_both!(self, |i| i.payload_mut())
    }
}

impl<'a> PacketSize for IpPacket<'a> {
    fn packet_size(&self) -> usize {
        match self {
            Self::Ipv4(p) => p.packet_size(),
            Self::Ipv6(p) => p.packet_size(),
        }
    }
}
