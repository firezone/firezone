//! Path selection for iceless snownet connections.
//!
//! A [`PathAgent`] picks which local/remote address pair a connection sends on
//! (its *primary*) and keeps that choice current as candidates come and go. It
//! replaces ICE for iceless connections: no roles, no nomination, no consent
//! checks. The model is a handful of orthogonal, composable pieces.
//!
//! ## WireGuard owns liveness
//!
//! Probes never kill a connection. A busy or spotty node drops probes while its
//! data still flows, and we must not retire it for that. The only authority on
//! whether a connection is dead is WireGuard's own state machine (an unanswered
//! re-key hitting its attempt timeout, or the session aging out). Everything
//! here only ever *informs* selection; it never tears a connection down.
//!
//! ## Probing and the settle rule
//!
//! Probes are ICMP echoes sent *inside* the WireGuard session, so a reply is
//! proof the tunnel works on that pair. Each pair probes in a front-loaded
//! burst that settles into a steady cadence (see the [`PROBE_BURST_GAPS`] /
//! [`PROBE_INTERVAL`] schedule), and one rule decides how long it probes:
//!
//! - it collects positive RTT samples until it has [`PROBE_SAMPLES`] of them,
//!   then **settles** and goes quiet — this is why a converged connection stops
//!   probing;
//! - a pair that never gets a reply never settles, so it **keeps probing** —
//!   until WireGuard retires the connection. Hunting for a path and going quiet
//!   after converging are the same rule seen from two sides.
//!
//! With one exception: once we already have a primary, a pair that won't settle
//! within [`PROBE_GIVE_UP`] is a dead end (e.g. a direct pair that can never
//! punch a symmetric NAT) and stops. We hunt indefinitely only while we have no
//! path at all.
//!
//! ## Re-evaluation (the scoped eval window)
//!
//! A settled pair is re-armed only by a signal that something may have changed:
//! a newly-signalled or peer-reflexive candidate arrives, or WireGuard shows
//! distress (a re-key we can't get answered, or the peer re-keying early). The
//! old global evaluation window still exists — but now it's implicit and scoped
//! to just the pairs a signal touches, e.g. the current primary and a freshly
//! arrived candidate, rather than a timer over all of them.
//!
//! ## Selection
//!
//! Given the pairs with an RTT, scoring ranks them by candidate kind, relay
//! placement and address family, with RTT only as a tie-breaker under
//! hysteresis so a working primary isn't displaced by a marginal gain. A worse
//! bucket never displaces the primary — it holds by candidate kind even while
//! being re-measured. Failing over to a worse-but-working path (e.g. direct to
//! relayed) happens only on a WireGuard distress signal, which drops the
//! primary pointer entirely so there is no longer a pair to protect and the
//! best surviving path wins.

mod agent;
mod candidate;
mod event;
mod icmpv6;
mod retransmit;
mod score;

pub use agent::{
    PROBE_BURST_GAPS, PROBE_GIVE_UP, PROBE_INTERVAL, PROBE_KEEPALIVE, PROBE_SAMPLES, PROBE_TIMEOUT,
    PathAgent, REKEY_DISTRESS_INTERVAL, RESPONDER_DEDUP_TTL,
};
pub use candidate::{Candidate, CandidateKind, ParseCandidateError};
pub use event::{Event, Payload, Transmit};
pub use icmpv6::{PROBE_DST, PROBE_SRC};
