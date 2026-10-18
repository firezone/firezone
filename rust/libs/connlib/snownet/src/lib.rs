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
pub use crypto::{DecryptJob, DecryptedPacket, EncryptJob};
pub use node::{
    ConnectionPath, Credentials, Encapsulation, Event, IceConfig, IceRole, Node, StillConnecting,
    Transmit, UnknownConnection,
};

bufferpool::buffer_pool!(static DATAGRAMS: Vec<u8> = (ip_packet::MAX_FZ_PAYLOAD, "snownet"), batch: 64);

/// Returns whether `payload` has the type and length of a WireGuard message.
///
/// This does not authenticate the message.
pub fn is_wireguard(payload: &[u8]) -> bool {
    let Some((ty, _)) = payload.split_first_chunk::<4>() else {
        return false;
    };

    matches!(
        (u32::from_le_bytes(*ty), payload.len()),
        (1, 148) | (2, 92) | (3, 64) | (4, 32..)
    )
}
