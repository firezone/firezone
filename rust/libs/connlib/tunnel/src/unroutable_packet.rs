use std::{
    fmt::Display,
    net::{IpAddr, SocketAddr},
};

use ip_packet::{IpNumber, IpPacket, Protocol};

#[derive(Debug, thiserror::Error)]
#[error("Unroutable packet: {error}")]
pub struct UnroutablePacket {
    five_tuple: FiveTuple,
    error: RoutingError,
}

impl UnroutablePacket {
    pub fn not_allowed(packet: &IpPacket) -> Self {
        Self {
            five_tuple: FiveTuple::for_packet(packet),
            error: RoutingError::NotAllowed,
        }
    }

    pub fn expired_nat_session(packet: &IpPacket) -> Self {
        Self {
            five_tuple: FiveTuple::for_packet(packet),
            error: RoutingError::ExpiredNatSession,
        }
    }

    pub fn not_a_peer(packet: &IpPacket) -> Self {
        Self {
            five_tuple: FiveTuple::for_packet(packet),
            error: RoutingError::NotAPeer,
        }
    }

    pub fn no_peer_state(packet: &IpPacket) -> Self {
        Self {
            five_tuple: FiveTuple::for_packet(packet),
            error: RoutingError::NoPeerState,
        }
    }

    pub fn not_connected(packet: &IpPacket) -> Self {
        Self {
            five_tuple: FiveTuple::for_packet(packet),
            error: RoutingError::NotConnected,
        }
    }

    pub fn outbound_icmp_error(packet: &IpPacket) -> Self {
        Self {
            five_tuple: FiveTuple::for_packet(packet),
            error: RoutingError::OutboundIcmpError,
        }
    }

    pub fn reason(&self) -> RoutingError {
        self.error
    }

    pub fn source(&self) -> impl Display {
        self.five_tuple.src
    }

    pub fn destination(&self) -> impl Display {
        self.five_tuple.dst
    }

    pub fn proto(&self) -> impl Display {
        self.five_tuple.proto.keyword_str().unwrap_or("unknown")
    }
}

#[derive(Debug, derive_more::Display, Clone, Copy)]
enum IpOrSocket {
    #[display("{_0}")]
    Ip(IpAddr),
    #[display("{_0}")]
    Socket(SocketAddr),
}

#[derive(Debug, Clone, Copy)]
struct FiveTuple {
    src: IpOrSocket,
    dst: IpOrSocket,
    proto: IpNumber,
}

impl FiveTuple {
    fn for_packet(p: &IpPacket) -> Self {
        let src_ip = p.source();
        let dst_ip = p.destination();
        let src_proto = p.source_protocol();
        let dst_proto = p.destination_protocol();

        match (src_proto, dst_proto) {
            (Ok(Protocol::Tcp(src_port)), Ok(Protocol::Tcp(dst_port))) => Self {
                src: IpOrSocket::Socket(SocketAddr::new(src_ip, src_port)),
                dst: IpOrSocket::Socket(SocketAddr::new(dst_ip, dst_port)),
                proto: p.next_header(),
            },
            (Ok(Protocol::Udp(src_port)), Ok(Protocol::Udp(dst_port))) => Self {
                src: IpOrSocket::Socket(SocketAddr::new(src_ip, src_port)),
                dst: IpOrSocket::Socket(SocketAddr::new(dst_ip, dst_port)),
                proto: p.next_header(),
            },
            (Ok(Protocol::IcmpEcho(_)), Ok(Protocol::IcmpEcho(_))) => Self {
                src: IpOrSocket::Ip(src_ip),
                dst: IpOrSocket::Ip(dst_ip),
                proto: p.next_header(),
            },
            _ => Self {
                src: IpOrSocket::Ip(src_ip),
                dst: IpOrSocket::Ip(dst_ip),
                proto: p.next_header(),
            },
        }
    }
}

#[derive(Debug, derive_more::Display, Clone, Copy, PartialEq, Eq)]
pub enum RoutingError {
    #[display("Not allowed")]
    NotAllowed,
    #[display("Expired NAT session")]
    ExpiredNatSession,
    #[display("Not a Firezone peer")]
    NotAPeer,
    #[display("No peer state")]
    NoPeerState,
    #[display("No connection")]
    NotConnected,
    #[display("OutboundIcmpError")]
    OutboundIcmpError,
    #[display("Other")]
    Other,
}

impl From<RoutingError> for opentelemetry::Value {
    fn from(value: RoutingError) -> Self {
        match value {
            RoutingError::NotAllowed => opentelemetry::Value::from("NotAllowed"),
            RoutingError::ExpiredNatSession => opentelemetry::Value::from("ExpiredNatSession"),
            RoutingError::NotAPeer => opentelemetry::Value::from("NotAPeer"),
            RoutingError::NoPeerState => opentelemetry::Value::from("NoPeerState"),
            RoutingError::NotConnected => opentelemetry::Value::from("NotConnected"),
            RoutingError::OutboundIcmpError => opentelemetry::Value::from("OutboundIcmpError"),
            RoutingError::Other => opentelemetry::Value::from("Other"),
        }
    }
}
