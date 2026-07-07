//! Path-selection state machine for iceless snownet connections.

mod agent;
mod candidate;
mod event;
mod icmpv6;
mod retransmit;
mod score;

pub use agent::{
    GUARD_SUSPENSION, PROBE_BURST_GAPS, PROBE_INTERVAL_LIVE, PROBE_TIMEOUT, PathAgent,
    REKEY_DISTRESS_INTERVAL, RESPONDER_DEDUP_TTL, RTT_FRESHNESS,
};
pub use candidate::{Candidate, CandidateKind, ParseCandidateError};
pub use event::{Event, Payload, Transmit};
pub use icmpv6::{PROBE_DST, PROBE_SRC};
