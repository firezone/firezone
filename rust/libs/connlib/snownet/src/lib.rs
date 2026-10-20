//! A SANS-IO connectivity library for wireguard connections formed by ICE.

#![cfg_attr(test, allow(clippy::unwrap_in_result))]
#![cfg_attr(test, allow(clippy::unwrap_used))]

mod agent;
mod allocation;
mod backoff;
mod candidate;
mod channel_data;
mod crypto;
mod node;
mod utils;

pub use allocation::RelaySocket;
pub use crypto::{Decapsulation, DecryptedPacket, Encapsulation};
pub use node::{
    ConnectionPath, Credentials, Event, IceConfig, IceRole, Node, StillConnecting, Transmit,
    UnknownConnection,
};

bufferpool::buffer_pool!(static DATAGRAMS: Vec<u8> = (ip_packet::MAX_FZ_PAYLOAD, "snownet"), batch: 64);
