use std::net::SocketAddr;

#[derive(Debug, Clone, PartialEq)]
pub struct Transmit {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub payload: Payload,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Payload {
    Ciphertext(Vec<u8>),
    Plaintext(Box<ip_packet::IpPacket>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    PrimaryChanged {
        local: SocketAddr,
        remote: SocketAddr,
    },
}

/// A message WireGuard wants to send to the peer.
#[derive(Debug, Clone, PartialEq)]
pub enum Outbound {
    HandshakeInitiation(Vec<u8>),
    HandshakeResponse(Vec<u8>),
    Data(Vec<u8>),
}

impl Outbound {
    pub fn into_bytes(self) -> Vec<u8> {
        match self {
            Outbound::HandshakeInitiation(bytes)
            | Outbound::HandshakeResponse(bytes)
            | Outbound::Data(bytes) => bytes,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandshakeKind {
    Initiation,
    Response,
}
