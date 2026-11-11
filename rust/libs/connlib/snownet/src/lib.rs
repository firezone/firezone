//! A SANS-IO connectivity library for wireguard connections formed by ICE.

#![cfg_attr(test, allow(clippy::unwrap_in_result))]
#![cfg_attr(test, allow(clippy::unwrap_used))]

mod agent;
mod candidate;
mod crypto;
mod node;

pub use crypto::{
    CommittedBatch, DecapsulateBatch, DecryptedBatch, EncapsulateBatch, PendingDecapsulate,
    PendingEncapsulate,
};
pub use node::{
    ConnectionPath, Credentials, Event, IceConfig, IceRole, Node, RemoteKind, StillConnecting,
    Transmit, UnknownConnection,
};
pub use relay_client_proto::RelaySocket;
