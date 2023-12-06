use std::net::IpAddr;

use domain::base::message::Message;
use pnet_packet::{
    icmpv6::{self, MutableIcmpv6Packet},
    ip::{IpNextHeaderProtocol, IpNextHeaderProtocols},
    ipv4::{self, Ipv4Packet, MutableIpv4Packet},
    ipv6::{Ipv6Packet, MutableIpv6Packet},
    tcp::{self, MutableTcpPacket, TcpPacket},
    udp::{self, MutableUdpPacket, UdpPacket},
    MutablePacket, Packet, PacketSize,
};

const DNS_PORT: u16 = 53;

#[derive(Debug, PartialEq)]
pub(crate) enum MutableIpPacket<'a> {
    MutableIpv4Packet(MutableIpv4Packet<'a>),
    MutableIpv6Packet(MutableIpv6Packet<'a>),
}

// no std::mem:;swap? no problem
macro_rules! swap_src_dst {
    ($p:expr) => {
        let src = $p.get_source();
        let dst = $p.get_destination();
        $p.set_source(dst);
        $p.set_destination(src);
    };
}

impl<'a> MutableIpPacket<'a> {
    #[inline]
    pub(crate) fn new(data: &mut [u8]) -> Option<MutableIpPacket> {
        let packet = match data[0] >> 4 {
            4 => MutableIpv4Packet::new(data)?.into(),
            6 => MutableIpv6Packet::new(data)?.into(),
            _ => return None,
        };

        Some(packet)
    }

    #[inline]
    pub(crate) fn destination(&self) -> IpAddr {
        match self {
            MutableIpPacket::MutableIpv4Packet(i) => i.get_destination().into(),
            MutableIpPacket::MutableIpv6Packet(i) => i.get_destination().into(),
        }
    }

    #[inline]
    pub(crate) fn update_checksum(&mut self) {
        // Note: neither ipv6 nor icmp have a checksum.
        self.set_icmpv6_checksum();
        self.set_udp_checksum();
        self.set_tcp_checksum();
        // Note: Ipv4 checksum should be set after the others,
        // since it's in an upper layer.
        self.set_ipv4_checksum();
    }

    pub(crate) fn set_ipv4_checksum(&mut self) {
        if let Self::MutableIpv4Packet(p) = self {
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
            .expect("Developer error: we can only get a checksum if the packet is udp")
            .set_checksum(checksum);
    }

    fn set_tcp_checksum(&mut self) {
        let checksum = if let Some(p) = self.as_immutable_tcp() {
            self.to_immutable().tcp_checksum(&p.to_immutable())
        } else {
            return;
        };

        self.as_tcp()
            .expect("Developer error: we can only get a checksum if the packet is tcp")
            .set_checksum(checksum);
    }

    pub(crate) fn to_immutable(&self) -> IpPacket {
        match self {
            Self::MutableIpv4Packet(p) => p.to_immutable().into(),
            Self::MutableIpv6Packet(p) => p.to_immutable().into(),
        }
    }

    pub(crate) fn as_immutable(&self) -> IpPacket<'_> {
        match self {
            Self::MutableIpv4Packet(p) => IpPacket::Ipv4Packet(p.to_immutable()),
            Self::MutableIpv6Packet(p) => IpPacket::Ipv6Packet(p.to_immutable()),
        }
    }

    pub(crate) fn as_udp(&mut self) -> Option<MutableUdpPacket> {
        self.to_immutable()
            .is_udp()
            .then(|| MutableUdpPacket::new(self.payload_mut()))
            .flatten()
    }

    fn as_tcp(&mut self) -> Option<MutableTcpPacket> {
        self.to_immutable()
            .is_tcp()
            .then(|| MutableTcpPacket::new(self.payload_mut()))
            .flatten()
    }

    fn set_icmpv6_checksum(&mut self) {
        let (src_addr, dst_addr) = match self {
            MutableIpPacket::MutableIpv4Packet(_) => return,
            MutableIpPacket::MutableIpv6Packet(p) => (p.get_source(), p.get_destination()),
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

    pub(crate) fn as_immutable_udp(&self) -> Option<UdpPacket> {
        self.to_immutable()
            .is_udp()
            .then(|| UdpPacket::new(self.payload()))
            .flatten()
    }

    pub(crate) fn as_immutable_tcp(&self) -> Option<TcpPacket> {
        self.to_immutable()
            .is_tcp()
            .then(|| TcpPacket::new(self.payload()))
            .flatten()
    }

    pub(crate) fn swap_src_dst(&mut self) {
        match self {
            Self::MutableIpv4Packet(p) => {
                swap_src_dst!(p);
            }
            Self::MutableIpv6Packet(p) => {
                swap_src_dst!(p);
            }
        }
    }

    #[inline]
    pub(crate) fn set_dst(&mut self, dst: IpAddr) {
        match (self, dst) {
            (Self::MutableIpv4Packet(p), IpAddr::V4(d)) => p.set_destination(d),
            (Self::MutableIpv6Packet(p), IpAddr::V6(d)) => p.set_destination(d),
            _ => {}
        }
    }

    #[inline]
    pub(crate) fn set_src(&mut self, src: IpAddr) {
        match (self, src) {
            (Self::MutableIpv4Packet(p), IpAddr::V4(s)) => p.set_source(s),
            (Self::MutableIpv6Packet(p), IpAddr::V6(s)) => p.set_source(s),
            _ => {}
        }
    }

    pub(crate) fn set_len(&mut self, total_len: usize, payload_len: usize) {
        match self {
            Self::MutableIpv4Packet(p) => p.set_total_length(total_len as u16),
            Self::MutableIpv6Packet(p) => p.set_payload_length(payload_len as u16),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Version {
    Ipv4,
    Ipv6,
}

#[derive(Debug, PartialEq)]
pub enum IpPacket<'a> {
    Ipv4Packet(Ipv4Packet<'a>),
    Ipv6Packet(Ipv6Packet<'a>),
}

impl<'a> IpPacket<'a> {
    pub(crate) fn owned(data: Vec<u8>) -> Option<IpPacket<'static>> {
        let packet = match data[0] >> 4 {
            4 => Ipv4Packet::owned(data)?.into(),
            6 => Ipv6Packet::owned(data)?.into(),
            _ => return None,
        };

        Some(packet)
    }

    pub(crate) fn to_owned(&self) -> IpPacket<'static> {
        // This should never fail as the provided buffer is a vec (unless oom)
        IpPacket::owned(self.packet().to_vec()).unwrap()
    }

    pub(crate) fn version(&self) -> Version {
        match self {
            IpPacket::Ipv4Packet(_) => Version::Ipv4,
            IpPacket::Ipv6Packet(_) => Version::Ipv6,
        }
    }

    pub(crate) fn is_icmpv6(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Icmpv6
    }

    pub(crate) fn next_header(&self) -> IpNextHeaderProtocol {
        match self {
            Self::Ipv4Packet(p) => p.get_next_level_protocol(),
            Self::Ipv6Packet(p) => p.get_next_header(),
        }
    }

    fn is_udp(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Udp
    }

    fn is_tcp(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Tcp
    }

    pub(crate) fn as_udp(&self) -> Option<UdpPacket> {
        self.is_udp()
            .then(|| UdpPacket::new(self.payload()))
            .flatten()
    }

    pub(crate) fn source(&self) -> IpAddr {
        match self {
            Self::Ipv4Packet(p) => p.get_source().into(),
            Self::Ipv6Packet(p) => p.get_source().into(),
        }
    }

    pub(crate) fn destination(&self) -> IpAddr {
        match self {
            Self::Ipv4Packet(p) => p.get_destination().into(),
            Self::Ipv6Packet(p) => p.get_destination().into(),
        }
    }

    pub(crate) fn udp_checksum(&self, dgm: &UdpPacket<'_>) -> u16 {
        match self {
            Self::Ipv4Packet(p) => udp::ipv4_checksum(dgm, &p.get_source(), &p.get_destination()),
            Self::Ipv6Packet(p) => udp::ipv6_checksum(dgm, &p.get_source(), &p.get_destination()),
        }
    }

    fn tcp_checksum(&self, pkt: &TcpPacket<'_>) -> u16 {
        match self {
            Self::Ipv4Packet(p) => tcp::ipv4_checksum(pkt, &p.get_source(), &p.get_destination()),
            Self::Ipv6Packet(p) => tcp::ipv6_checksum(pkt, &p.get_source(), &p.get_destination()),
        }
    }
}

pub(crate) fn to_dns<'a>(pkt: &'a UdpPacket<'a>) -> Option<&'a Message<[u8]>> {
    (pkt.get_destination() == DNS_PORT)
        .then(|| Message::from_slice(pkt.payload()).ok())
        .flatten()
}

impl<'a> Packet for IpPacket<'a> {
    fn packet(&self) -> &[u8] {
        match self {
            Self::Ipv4Packet(p) => p.packet(),
            Self::Ipv6Packet(p) => p.packet(),
        }
    }

    fn payload(&self) -> &[u8] {
        match self {
            Self::Ipv4Packet(p) => p.payload(),
            Self::Ipv6Packet(p) => p.payload(),
        }
    }
}

impl<'a> PacketSize for IpPacket<'a> {
    fn packet_size(&self) -> usize {
        match self {
            Self::Ipv4Packet(p) => p.packet_size(),
            Self::Ipv6Packet(p) => p.packet_size(),
        }
    }
}

impl<'a> Packet for MutableIpPacket<'a> {
    fn packet(&self) -> &[u8] {
        match self {
            Self::MutableIpv4Packet(p) => p.packet(),
            Self::MutableIpv6Packet(p) => p.packet(),
        }
    }

    fn payload(&self) -> &[u8] {
        match self {
            Self::MutableIpv4Packet(p) => p.payload(),
            Self::MutableIpv6Packet(p) => p.payload(),
        }
    }
}

impl<'a> MutablePacket for MutableIpPacket<'a> {
    fn packet_mut(&mut self) -> &mut [u8] {
        match self {
            Self::MutableIpv4Packet(p) => p.packet_mut(),
            Self::MutableIpv6Packet(p) => p.packet_mut(),
        }
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        match self {
            Self::MutableIpv4Packet(p) => p.payload_mut(),
            Self::MutableIpv6Packet(p) => p.payload_mut(),
        }
    }
}

impl<'a> From<Ipv4Packet<'a>> for IpPacket<'a> {
    fn from(pkt: Ipv4Packet<'a>) -> Self {
        Self::Ipv4Packet(pkt)
    }
}

impl<'a> From<Ipv6Packet<'a>> for IpPacket<'a> {
    fn from(pkt: Ipv6Packet<'a>) -> Self {
        Self::Ipv6Packet(pkt)
    }
}

impl<'a> From<MutableIpv4Packet<'a>> for MutableIpPacket<'a> {
    fn from(pkt: MutableIpv4Packet<'a>) -> Self {
        Self::MutableIpv4Packet(pkt)
    }
}

impl<'a> From<MutableIpv6Packet<'a>> for MutableIpPacket<'a> {
    fn from(pkt: MutableIpv6Packet<'a>) -> Self {
        Self::MutableIpv6Packet(pkt)
    }
}
