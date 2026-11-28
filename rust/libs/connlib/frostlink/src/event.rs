use std::net::SocketAddr;

#[derive(Debug, Clone, PartialEq)]
pub struct Transmit {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub payload: Payload,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Payload {
    ProbeRequest(Box<ip_packet::IpPacket>),
    ProbeReply(Box<ip_packet::IpPacket>),
    /// A re-key on the primary, or the bootstrap fan-out over the relay pairs.
    HandshakeInitiation(sanstun::Datagram),
    /// Answers a handshake initiation, also when replayed from the cache.
    HandshakeResponse(sanstun::Datagram),
    /// Confirms a handshake response on the path it arrived on.
    Keepalive(sanstun::Datagram),
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
