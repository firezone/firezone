//! Path-selection state machine for ICE-less snownet connections.
//!
//! Pure path bookkeeping: it does not know about WireGuard, TURN, or any
//! particular transport. The owning `snownet` connection drives it by
//! reporting evidence (a handshake or probe round-tripped on this pair) and
//! asks back which pair to send from.
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
//! The scoring weights and the probe schedule live in later commits;
//! this crate currently exposes the data types and a `PathAgent`
//! skeleton driven by `add_*_candidate` and `observe_*`.

mod agent;
mod candidate;

pub use agent::{PathAgent, PathEvent};
pub use candidate::{Candidate, CandidateKind};
