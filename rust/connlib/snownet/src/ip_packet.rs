use std::net::IpAddr;

use pnet_packet::{
    ip::IpNextHeaderProtocols,
    ipv4::{Ipv4Packet, MutableIpv4Packet},
    ipv6::{Ipv6Packet, MutableIpv6Packet},
    Packet,
};

macro_rules! for_both {
    ($this:ident, |$name:ident| $body:expr) => {
        match $this {
            Self::Ipv4($name) => $body,
            Self::Ipv6($name) => $body,
        }
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

    pub fn to_owned(&self) -> MutableIpPacket<'static> {
        match self {
            MutableIpPacket::Ipv4(i) => MutableIpv4Packet::owned(i.packet().to_vec())
                .expect("owned packet is still valid")
                .into(),
            MutableIpPacket::Ipv6(i) => MutableIpv6Packet::owned(i.packet().to_vec())
                .expect("owned packet is still valid")
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
                .expect("owned packet is still valid")
                .into(),
            IpPacket::Ipv6(i) => Ipv6Packet::owned(i.packet().to_vec())
                .expect("owned packet is still valid")
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
