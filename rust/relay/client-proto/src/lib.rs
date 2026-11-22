//! A sans-IO implementation of the client side of the TURN protocol.

#![cfg_attr(test, allow(clippy::unwrap_in_result))]
#![cfg_attr(test, allow(clippy::unwrap_used))]

mod allocation;
mod backoff;
pub mod channel_data;

pub use allocation::{
    Allocation, Attribute, EncodeOk, Event, FreeReason, RelaySocket, Socket, Transmit, decode,
};
