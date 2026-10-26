//! A [`ClientTunnel`](tunnel::ClientTunnel) / [`GatewayTunnel`](tunnel::GatewayTunnel) event loop
//! that Callgrind can count the instructions of: a [`Host`](crate::fixture::Host), of which only
//! [`Host::run`](crate::fixture::Host::run) is counted.

mod idle;
mod packets;

pub use idle::Idle;
pub use packets::{Direction, Packets};
