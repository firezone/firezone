//! A SANS-IO connectivity library for wireguard connections formed by ICE.

mod allocation;
mod backoff;
mod channel_data;
mod index;
mod node;
mod ringbuffer;
mod stats;
mod utils;

pub use allocation::RelaySocket;
pub use node::{
    Answer, Client, ClientNode, Credentials, Error, Event, Node, Offer, Server, ServerNode,
    Transmit, HANDSHAKE_TIMEOUT,
};
pub use stats::{ConnectionStats, NodeStats};
