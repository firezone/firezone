use std::net::SocketAddr;

#[derive(Debug, Clone, PartialEq)]
pub struct Transmit {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub payload: Payload,
    /// Whether this answers something the remote sent, rather than being initiated by us.
    pub reply: bool,
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
