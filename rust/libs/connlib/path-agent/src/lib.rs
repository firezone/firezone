//! Path-selection state machine for iceless snownet connections.

mod agent;
mod candidate;
mod event;
mod icmpv6;
mod retransmit;
mod score;
mod validator;

pub use agent::{EVALUATION_WINDOW, PROBE_INTERVAL, PROBE_INTERVAL_LIVE, PROBE_TIMEOUT, PathAgent};
pub use candidate::{Candidate, CandidateKind};
pub use event::{Event, Payload, Transmit};
pub use icmpv6::{PROBE_DST, PROBE_SRC};
pub use validator::{Accepted, HandshakeValidator, Rejected};
