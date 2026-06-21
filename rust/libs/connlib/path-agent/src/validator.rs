//! Hook for the noise-state authoritative source. Implemented in
//! production by a thin wrapper around `boringtun::noise::Tunn`; in
//! tests by a mock that lets handshake bytes stay synthetic.
//!
//! [`PathAgent::handle_inbound_network`] consults this before any
//! state mutation tied to a fresh handshake, so bytes that fail
//! validation leave the path-agent's dedup / evaluation-window /
//! primary state untouched.
//!
//! [`PathAgent::handle_inbound_network`]: crate::PathAgent::handle_inbound_network

use std::time::Instant;

/// Marker for a validator-rejected handshake. Carries no payload —
/// the validator logs the underlying cause itself; `PathAgent` just
/// needs to know it must not commit any state.
#[derive(Debug)]
pub struct Rejected;

/// Outcome of a validator call that did not reject the bytes.
#[derive(Debug)]
pub enum Accepted {
    /// The noise session advanced. Any bytes reported via `on_outbound`
    /// are the `HandshakeResponse` and/or data packets the implementation
    /// had buffered while handshake-pending; `PathAgent` commits its
    /// session / path state and routes them.
    Session,
    /// The bytes only passed a MAC1 check and the implementation answered
    /// with a cookie reply because it is under load. The sender's address
    /// is unauthenticated, so `PathAgent` commits no state; it returns the
    /// cookie reported via `on_outbound` to the sender on the receive path
    /// so a legitimate peer can retry with a valid MAC2.
    Cookie,
}

/// Validates inbound WG handshake bytes. Outbound packets the
/// implementation produces during validation (typically the
/// `HandshakeResponse` when accepting an `Init`, any data packets the
/// responder buffered while handshake-pending, or a cookie reply under
/// load) are reported via `on_outbound`. Returns `Err(Rejected)` to abort
/// the call without any path-agent state mutation; see [`Accepted`] for
/// how the success variants are routed.
pub trait HandshakeValidator {
    fn validate(
        &mut self,
        bytes: &[u8],
        now: Instant,
        on_outbound: &mut dyn FnMut(Vec<u8>),
    ) -> Result<Accepted, Rejected>;
}
