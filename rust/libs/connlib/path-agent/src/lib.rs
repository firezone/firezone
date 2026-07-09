//! Path selection for iceless WireGuard connections.
//!
//! ICEless is inspired by ICE but optimised for WireGuard. A [`PathAgent`]
//! only *selects* a path (which local/remote address pair a connection sends
//! on — its *primary*); WireGuard owns the session and liveness.
//!
//! ## Bootstrap
//!
//! Probes ride the WireGuard session, so a session must exist before any path
//! can be probed. To get one, the agent fans a boringtun `init` out over every
//! pair that involves a relay candidate — relays are always reachable, even
//! behind double symmetric NAT. A session is *established* the moment we see a
//! handshake (an init or a response), and the establishing handshake seeds a
//! preliminary primary: the relay pair it arrived on. That is sound because the
//! fan-out only uses relays (the worst tier), so probing can only promote away
//! from it, and it gives both ends a working path — and thus a connection that
//! carries data — the instant the session exists, rather than after the first
//! probe reply. A mid-session re-key never moves the primary; probing decides.
//!
//! Handshakes are always answered on the path they arrived on, never on the
//! primary — routine re-keys included.
//!
//! ## Probing and selection
//!
//! Once established, every pair probes with ICMPv6 echo requests (the `id` is
//! scoped to the pair). A reply is proof the path works both ways and carries
//! its RTT. Pairs are ranked by tier then RTT, and **probes can only promote
//! the primary, never demote it**: the best measured pair takes an empty
//! primary or displaces the incumbent only when it scores strictly better.
//!
//! A pair goes quiet after [`PROBE_BUDGET`] probes — *unless* it is the primary
//! (which keeps a slow [`PRIMARY_KEEPALIVE`] cadence so an idle connection's NAT
//! bindings and tunnel stay alive; iceless runs no WireGuard persistent
//! keepalive), or there is no primary at all (in which case every pair hunts
//! forever until one is found). The agent never declares the connection broken;
//! without a path WireGuard simply can't re-key and the connection is torn down
//! after ~180s.
//!
//! ## Distress and re-probing
//!
//! The primary is dropped only on a signal that it is dead. WireGuard re-keys
//! when its data goes unanswered; because every WireGuard packet flows through
//! the agent, a second unanswered re-key (ours) — or a second distinct peer
//! init with no data in between — is taken as distress ([`REKEY_DISTRESS_ATTEMPTS`]),
//! clearing the primary and re-probing every pair. A new candidate is the same
//! kind of signal and does the same. Pairs already probing keep their state.
//!
//! NAT bindings along the primary are kept warm by WireGuard's persistent
//! keepalive, not by probes.

mod agent;
mod candidate;
mod event;
mod icmpv6;
mod retransmit;
mod score;

pub use agent::{
    PRIMARY_KEEPALIVE, PROBE_BUDGET, PROBE_BURST_GAPS, PROBE_INTERVAL, PathAgent,
    REKEY_DISTRESS_ATTEMPTS, RESPONDER_DEDUP_TTL,
};
pub use candidate::{Candidate, CandidateKind, ParseCandidateError};
pub use event::{Event, Payload, Transmit};
pub use icmpv6::{PROBE_DST, PROBE_SRC};
