//! A SANS-IO connectivity library for wireguard connections formed by ICE.

#![cfg_attr(test, allow(clippy::unwrap_in_result))]
#![cfg_attr(test, allow(clippy::unwrap_used))]

mod allocation;
mod backoff;
mod channel_data;
mod index;
mod node;
mod stats;
mod utils;

pub use allocation::RelaySocket;
pub use node::{
    Client, ClientNode, Credentials, Event, HANDSHAKE_TIMEOUT, NoTurnServers, Node, Server,
    ServerNode, Transmit, UnknownConnection,
};
pub use stats::{ConnectionStats, NodeStats};

pub fn is_wireguard(payload: &[u8]) -> bool {
    boringtun::noise::Tunn::parse_incoming_packet(payload).is_ok()
}

pub(crate) fn is_handshake(payload: &[u8]) -> bool {
    use boringtun::noise::Packet;

    boringtun::noise::Tunn::parse_incoming_packet(payload)
        .is_ok_and(|p| matches!(p, Packet::HandshakeInit(_) | Packet::HandshakeResponse(_)))
}
