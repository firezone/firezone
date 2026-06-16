//! Outputs the path-agent hands back to snownet, drained via
//! `PathAgent::poll_transmit` / `PathAgent::poll_event`.

use std::net::SocketAddr;

/// Outbound transmit. snownet picks the wire transport (host send vs.
/// TURN channel-data) from `local`.
#[derive(Debug, Clone, PartialEq)]
pub struct Transmit {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub payload: Payload,
}

/// `Ciphertext`: already-encrypted WG bytes (handshake fanout,
/// retransmits, dedup replays). `Plaintext`: an inner IP packet
/// snownet must run through `Tunn::encapsulate` first — probes only.
#[derive(Debug, Clone, PartialEq)]
pub enum Payload {
    Ciphertext(Vec<u8>),
    Plaintext(Box<ip_packet::IpPacket>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Primary path set or re-selected. snownet adopts the pair as
    /// its `peer_socket`.
    PrimaryChanged {
        local: SocketAddr,
        remote: SocketAddr,
    },
    /// Inbound handshake bytes the caller must feed to `Tunn::decapsulate_at`.
    ForwardHandshake { bytes: Vec<u8> },
}
