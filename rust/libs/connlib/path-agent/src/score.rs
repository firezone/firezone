//! Smaller-is-better ranking of `(local, remote)` pairs for primary
//! path selection. `agent::pair_score` maps a pair's state into a
//! [`PairScore`]; `PathAgent::select_primary` picks the minimum.

use std::net::SocketAddr;
use std::time::Duration;

use crate::agent::PairState;

/// Which end of the pair carries the relay. Within the Relayed tier,
/// prefer our own relay so a relay rotation stays a local-only concern
/// (no invalidated remote candidate to signal back to the peer).
#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum RelayEnd {
    Local,
    Remote,
}

/// Whether the relay has to bridge address families internally.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum FamilyMatch {
    Matched,
    Mismatched,
}

/// Address family of the local send socket. v6 paths are generally
/// shorter and our gear is dual-stack, so prefer them.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum LocalFamily {
    V6,
    V4,
}

/// Smaller-is-better discrete preference bucket. Field order is the
/// comparison priority; each axis is an enum whose variants are
/// declared best-first, so derived `Ord` ranks pairs without leaning
/// on any `bool` ordering convention. These are categorical: a strict
/// win here switches the primary regardless of RTT. Pairs in the same
/// bucket are separated only by RTT.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Bucket {
    /// Worse-of-pair candidate kind. `Host < ServerReflexive < Relayed`,
    /// so direct beats relayed.
    pub(crate) tier: crate::CandidateKind,
    pub(crate) relay_end: RelayEnd,
    pub(crate) family_match: FamilyMatch,
    pub(crate) local_family: LocalFamily,
}

/// Smaller-is-better sort key for primary selection: the discrete
/// [`Bucket`] followed by smoothed RTT. Derived `Ord` compares the
/// bucket first and only races on latency once every categorical
/// preference ties.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct PairScore {
    pub(crate) bucket: Bucket,
    pub(crate) rtt: Option<Duration>,
}

/// Map a pair's current state into its [`PairScore`] ranking key.
pub(crate) fn pair_score(pair: (SocketAddr, SocketAddr), state: &PairState) -> PairScore {
    PairScore {
        bucket: Bucket {
            tier: state.kinds.0.max(state.kinds.1),
            relay_end: if matches!(state.kinds.0, crate::CandidateKind::Relayed) {
                RelayEnd::Local
            } else {
                RelayEnd::Remote
            },
            family_match: if state.local_family_matched {
                FamilyMatch::Matched
            } else {
                FamilyMatch::Mismatched
            },
            local_family: if pair.0.is_ipv6() {
                LocalFamily::V6
            } else {
                LocalFamily::V4
            },
        },
        rtt: state.smoothed_rtt,
    }
}
