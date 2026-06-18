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

/// Validates inbound WG handshake bytes. Outbound packets the
/// implementation produces during validation (typically the
/// `HandshakeResponse` when accepting an `Init`, or any data packets
/// the responder buffered while handshake-pending) are reported via
/// `on_outbound`. Returns `Err(Rejected)` to abort the call without
/// any path-agent state mutation.
pub trait HandshakeValidator {
    fn validate(
        &mut self,
        bytes: &[u8],
        now: Instant,
        on_outbound: &mut dyn FnMut(Vec<u8>),
    ) -> Result<(), Rejected>;
}
