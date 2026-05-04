//! Path-selection state machine for ICE-less snownet connections.
//!
//! `PathAgent` mediates between boringtun's WireGuard state machine and the
//! IO layer. snownet hands every encapsulated outbound byte slice to
//! [`PathAgent::handle_outbound`] and every inbound byte slice (with the
//! `(local, remote)` path it arrived on) to [`PathAgent::handle_inbound`].
//! `PathAgent` parses the bytes with boringtun, decides what to do (fanout,
//! dedup, replay, etc.), and emits work via [`PathAgent::poll_transmit`]
//! and [`PathAgent::poll_event`].
//!
//! Public API works exclusively in `(local, remote)` `SocketAddr` pairs so
//! callers don't need to maintain a parallel mapping of opaque pair IDs to
//! sockets. Internal demultiplexing for ICMPv6 echo `id` is handled within
//! the crate.
//!
//! Scoring inputs:
//! - tier (`CandidateKind` of each side; direct paths beat relayed paths)
//! - handshake observation (we received a WG init or response on this pair)
//! - probe RTT (smoothed, populated by ICMPv6 echo round-trips)
//!
//! Scoring weights, probe scheduling, retransmit ladders, and the
//! handshake-dedup caches are filled in by subsequent commits.

mod agent;
mod candidate;
mod icmpv6;

pub use agent::{
    BOOTSTRAP_WINDOW, Event, PROBE_INTERVAL, PROBE_INTERVAL_LIVE, PathAgent, PathEvent, Payload,
    Transmit,
};
pub use candidate::{Candidate, CandidateKind};
pub use icmpv6::{PROBE_DST, PROBE_SRC};
