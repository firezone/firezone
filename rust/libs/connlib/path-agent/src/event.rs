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
    /// Probes regained a path after we had none (e.g. after a roam).
    ///
    /// The kept session already flows again; a re-key on the new primary lets
    /// the remote know our situation changed so it can re-evaluate, too.
    PathRecovered,
}
