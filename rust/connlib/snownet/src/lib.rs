//! A SANS-IO connectivity library for wireguard connections formed by ICE.

#![cfg_attr(test, allow(clippy::unwrap_in_result))]
#![cfg_attr(test, allow(clippy::unwrap_used))]

mod allocation;
mod backoff;
mod candidate_set;
mod channel_data;
mod index;
mod node;
mod stats;
mod utils;

pub use allocation::RelaySocket;
#[allow(deprecated)] // Rust bug: `expect` doesn't seem to work on imports?
pub use node::{Answer, Offer};
pub use node::{
    Client, ClientNode, Credentials, EncryptedPacket, Error, Event, HANDSHAKE_TIMEOUT,
    NoTurnServers, Node, Server, ServerNode, Transmit,
};
pub use stats::{ConnectionStats, NodeStats};
