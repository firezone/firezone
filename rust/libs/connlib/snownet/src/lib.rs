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
pub use crypto::{DecryptedIpPacket, PendingDecapsulate, PendingEncapsulate};
pub use node::{
    ConnectionPath, Credentials, Event, IceConfig, IceRole, Node, StillConnecting, Transmit,
    UnknownConnection,
};
