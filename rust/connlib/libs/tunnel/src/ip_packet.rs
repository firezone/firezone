use std::net::IpAddr;

use domain::base::message::Message;
use pnet::packet::{
    ip::{IpNextHeaderProtocol, IpNextHeaderProtocols},
    ipv4::{checksum, Ipv4Packet, MutableIpv4Packet},
    ipv6::{Ipv6Packet, MutableIpv6Packet},
    udp::{ipv4_checksum, ipv6_checksum, MutableUdpPacket, UdpPacket},
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
    pub(crate) fn new(data: &mut [u8]) -> Option<MutableIpPacket> {
        match data[0] >> 4 {
            4 => MutableIpv4Packet::new(data).map(Into::into),
            6 => MutableIpv6Packet::new(data).map(Into::into),
            _ => None,
        }
    }

    pub(crate) fn set_checksum(&mut self) {
        if let Self::MutableIpv4Packet(p) = self {
            p.set_checksum(checksum(&p.to_immutable()));
        }
    }

    pub(crate) fn to_immutable(&self) -> IpPacket {
        match self {
            Self::MutableIpv4Packet(p) => p.to_immutable().into(),
            Self::MutableIpv6Packet(p) => p.to_immutable().into(),
        }
    }

    pub(crate) fn as_udp(&mut self) -> Option<MutableUdpPacket> {
        self.to_immutable()
            .is_udp()
            .then(|| MutableUdpPacket::new(self.payload_mut()))
            .flatten()
    }

    pub(crate) fn as_immutable_udp(&self) -> Option<UdpPacket> {
        self.to_immutable()
            .is_udp()
            .then(|| UdpPacket::new(self.payload()))
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

    pub(crate) fn set_len(&mut self, total_len: usize, payload_len: usize) {
        match self {
            Self::MutableIpv4Packet(p) => p.set_total_length(total_len as u16),
            Self::MutableIpv6Packet(p) => p.set_payload_length(payload_len as u16),
        }
    }
}

#[derive(Debug, PartialEq)]
pub(crate) enum IpPacket<'a> {
    Ipv4Packet(Ipv4Packet<'a>),
    Ipv6Packet(Ipv6Packet<'a>),
}

impl<'a> IpPacket<'a> {
    pub(crate) fn new(data: &[u8]) -> Option<IpPacket> {
        match data[0] >> 4 {
            4 => Ipv4Packet::new(data).map(Into::into),
            6 => Ipv6Packet::new(data).map(Into::into),
            _ => None,
        }
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

    pub(crate) fn as_udp(&self) -> Option<UdpPacket> {
        self.is_udp()
            .then(|| UdpPacket::new(self.payload()))
            .flatten()
    }

    pub(crate) fn destination(&self) -> IpAddr {
        match self {
            Self::Ipv4Packet(p) => p.get_destination().into(),
            Self::Ipv6Packet(p) => p.get_destination().into(),
        }
    }

    pub(crate) fn udp_checksum(&self, dgm: &UdpPacket<'_>) -> u16 {
        match self {
            Self::Ipv4Packet(p) => ipv4_checksum(dgm, &p.get_source(), &p.get_destination()),
            Self::Ipv6Packet(p) => ipv6_checksum(dgm, &p.get_source(), &p.get_destination()),
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
