//! Path-selection state machine for iceless snownet connections. See
//! [`PathAgent`] for the lifecycle and the bigger picture.

mod agent;
mod candidate;
mod icmpv6;

pub use agent::{
    BOOTSTRAP_WINDOW, Event, PROBE_INTERVAL, PROBE_INTERVAL_LIVE, PROBE_TIMEOUT, PathAgent,
    Payload, Transmit,
};
pub use candidate::{Candidate, CandidateKind};
pub use icmpv6::{PROBE_DST, PROBE_SRC};
