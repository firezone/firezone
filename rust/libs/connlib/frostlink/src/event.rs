use std::net::SocketAddr;

#[derive(Debug, Clone, PartialEq)]
pub struct Transmit {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub payload: Payload,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Outgoing {
    ProbeRequest(Transmit),
    ProbeReply(Transmit),
    /// A re-key on the primary, or the bootstrap fan-out over the relay pairs.
    HandshakeInitiation(Transmit),
    /// Answers a handshake initiation, also when replayed from the cache.
    HandshakeResponse(Transmit),
    /// Confirms a handshake response on the path it arrived on.
    Keepalive(Transmit),
}

impl Outgoing {
    pub fn into_transmit(self) -> Transmit {
        match self {
            Outgoing::ProbeRequest(t)
            | Outgoing::ProbeReply(t)
            | Outgoing::HandshakeInitiation(t)
            | Outgoing::HandshakeResponse(t)
            | Outgoing::Keepalive(t) => t,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Payload {
    Ciphertext(sanstun::Datagram),
    Plaintext(Box<ip_packet::IpPacket>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    PrimaryChanged {
        local: SocketAddr,
        remote: SocketAddr,
    },
    /// A probe we sent on this pair was answered for the first time since the pair was created
    /// or restarted, proving the path works both ways.
    PathValidated {
        local: SocketAddr,
        remote: SocketAddr,
    },
}
