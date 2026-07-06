//! Smaller-is-better ranking of `(local, remote)` pairs for primary
//! path selection. Bucket field order is the comparison priority;
//! variants of each axis are declared best-first.

use std::net::SocketAddr;
use std::time::Duration;

use crate::agent::PairState;

#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum RelayEnd {
    Local,
    Remote,
}

#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum FamilyMatch {
    Matched,
    Mismatched,
}

#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum LocalFamily {
    V6,
    V4,
}

#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Bucket {
    /// `Host < ServerReflexive < Relayed`; the worse end, then the better
    /// end. Comparing both ends keeps e.g. relay->srflx (one relay hop)
    /// ahead of relay->relay (two) instead of tying them on RTT.
    pub(crate) tier: (crate::CandidateKind, crate::CandidateKind),
    pub(crate) relay_end: RelayEnd,
    pub(crate) family_match: FamilyMatch,
    pub(crate) local_family: LocalFamily,
}

#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct PairScore {
    pub(crate) bucket: Bucket,
    pub(crate) rtt: Option<Duration>,
}

pub(crate) fn pair_score(pair: (SocketAddr, SocketAddr), state: &PairState) -> PairScore {
    PairScore {
        bucket: Bucket {
            tier: {
                let (local, remote) = state.kinds;

                (local.max(remote), local.min(remote))
            },
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
