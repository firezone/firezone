mod index;
mod pool;

use std::net::IpAddr;

use pnet_packet::{ip::IpNextHeaderProtocols, ipv4::Ipv4Packet, ipv6::Ipv6Packet, Packet};
pub use pool::{
    Answer, ClientConnectionPool, ConnectionPool, Credentials, Error, Event, Offer,
    ServerConnectionPool,
};

macro_rules! for_both {
    ($this:ident, |$name:ident| $body:expr) => {
        match $this {
            IpPacket::Ipv4($name) => $body,
            IpPacket::Ipv6($name) => $body,
        }
    };
}

#[derive(Debug, PartialEq)]
pub enum IpPacket<'a> {
    Ipv4(Ipv4Packet<'a>),
    Ipv6(Ipv6Packet<'a>),
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

impl pnet_packet::Packet for IpPacket<'_> {
    fn packet(&self) -> &[u8] {
        for_both!(self, |i| i.packet())
    }

    fn payload(&self) -> &[u8] {
        for_both!(self, |i| i.payload())
    }
}
