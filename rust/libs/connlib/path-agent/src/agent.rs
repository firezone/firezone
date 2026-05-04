use std::collections::{BTreeMap, VecDeque};
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use crate::candidate::Candidate;

/// Path-selection state machine.
///
/// Tracks the set of candidate pairs and which one is currently the best
/// outbound path. Driven by the owning snownet connection: candidates flow
/// in via [`PathAgent::add_local_candidate`] / [`PathAgent::add_remote_candidate`],
/// evidence flows in via [`PathAgent::observe_handshake`] /
/// [`PathAgent::observe_probe`], and decisions flow out via
/// [`PathAgent::poll_event`] and [`PathAgent::primary`].
///
/// All public APIs identify pairs by `(local, remote)` `SocketAddr` tuples
/// so callers don't need to maintain a parallel mapping.
pub struct PathAgent {
    locals: Vec<Candidate>,
    remotes: Vec<Candidate>,
    pairs: BTreeMap<(SocketAddr, SocketAddr), PairState>,
    primary: Option<(SocketAddr, SocketAddr)>,
    events: VecDeque<PathEvent>,
}

struct PairState {
    /// Kinds of the local + remote candidate, captured at insertion time.
    kinds: (crate::CandidateKind, crate::CandidateKind),
    /// Last observed handshake on this pair.
    last_handshake_at: Option<Instant>,
    /// Smoothed RTT, populated from probe round-trips.
    smoothed_rtt: Option<Duration>,
}

impl PairState {
    fn involves_relay(&self) -> bool {
        matches!(self.kinds.0, crate::CandidateKind::Relayed)
            || matches!(self.kinds.1, crate::CandidateKind::Relayed)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathEvent {
    /// First time we have a primary path.
    PrimarySelected {
        local: SocketAddr,
        remote: SocketAddr,
    },
    /// Primary path changed mid-life.
    PrimaryChanged {
        from: (SocketAddr, SocketAddr),
        to: (SocketAddr, SocketAddr),
    },
}

impl Default for PathAgent {
    fn default() -> Self {
        Self::new()
    }
}

impl PathAgent {
    pub fn new() -> Self {
        Self {
            locals: Vec::new(),
            remotes: Vec::new(),
            pairs: BTreeMap::new(),
            primary: None,
            events: VecDeque::new(),
        }
    }

    pub fn add_local_candidate(&mut self, c: Candidate) {
        if self.locals.contains(&c) {
            return;
        }
        self.locals.push(c);
        for &remote in &self.remotes.clone() {
            self.add_pair(c, remote);
        }
    }

    pub fn add_remote_candidate(&mut self, c: Candidate) {
        if self.remotes.contains(&c) {
            return;
        }
        self.remotes.push(c);
        for &local in &self.locals.clone() {
            self.add_pair(local, c);
        }
    }

    fn add_pair(&mut self, local: Candidate, remote: Candidate) {
        self.pairs.insert(
            (local.addr, remote.addr),
            PairState {
                kinds: (local.kind, remote.kind),
                last_handshake_at: None,
                smoothed_rtt: None,
            },
        );
    }

    /// Note that a WG handshake message (init or response) was received on
    /// this pair. Used to seed initial scoring before probes have data.
    pub fn observe_handshake(&mut self, local: SocketAddr, remote: SocketAddr, now: Instant) {
        if let Some(state) = self.pairs.get_mut(&(local, remote)) {
            state.last_handshake_at = Some(now);
        }
    }

    /// Note an observed RTT for this pair (one ICMPv6 echo round-trip).
    pub fn observe_probe(&mut self, local: SocketAddr, remote: SocketAddr, rtt: Duration) {
        if let Some(state) = self.pairs.get_mut(&(local, remote)) {
            // Placeholder smoothing — proper EMA arrives with the probe loop.
            state.smoothed_rtt = Some(match state.smoothed_rtt {
                None => rtt,
                Some(prev) => (prev + rtt) / 2,
            });
        }
    }

    /// Currently-best send pair, if any.
    pub fn primary(&self) -> Option<(SocketAddr, SocketAddr)> {
        self.primary
    }

    /// Iterate every relay-involved pair. The initial WG handshake fans out
    /// across this set.
    pub fn relay_pairs(&self) -> impl Iterator<Item = (SocketAddr, SocketAddr)> + '_ {
        self.pairs
            .iter()
            .filter(|(_, state)| state.involves_relay())
            .map(|(addrs, _)| *addrs)
    }

    /// Iterate every known pair as `(local, remote)`.
    pub fn pairs(&self) -> impl Iterator<Item = (SocketAddr, SocketAddr)> + '_ {
        self.pairs.keys().copied()
    }

    /// Whether `addr` matches a known remote candidate of relay kind. Used by
    /// the snownet-side dispatch to classify the destination of a freshly
    /// emitted send pair.
    pub fn remote_is_relayed(&self, addr: SocketAddr) -> bool {
        self.remotes
            .iter()
            .any(|c| c.addr == addr && c.is_relayed())
    }

    pub fn poll_event(&mut self) -> Option<PathEvent> {
        self.events.pop_front()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candidate::Candidate;

    fn addr(p: u16) -> SocketAddr {
        format!("127.0.0.1:{p}").parse().unwrap()
    }

    #[test]
    fn new_agent_has_no_pairs_or_primary() {
        let a = PathAgent::new();
        assert!(a.primary().is_none());
        assert_eq!(a.pairs().count(), 0);
        assert_eq!(a.relay_pairs().count(), 0);
    }

    #[test]
    fn pairs_form_cartesian_product_of_locals_and_remotes() {
        let mut a = PathAgent::new();
        a.add_local_candidate(Candidate::host(addr(1)));
        a.add_local_candidate(Candidate::relayed(addr(2)));
        a.add_remote_candidate(Candidate::host(addr(3)));
        a.add_remote_candidate(Candidate::relayed(addr(4)));

        // 2 × 2 = 4 pairs
        assert_eq!(a.pairs().count(), 4);
    }

    #[test]
    fn relay_pairs_filters_correctly() {
        let mut a = PathAgent::new();
        a.add_local_candidate(Candidate::host(addr(1)));
        a.add_local_candidate(Candidate::relayed(addr(2)));
        a.add_remote_candidate(Candidate::host(addr(3)));
        a.add_remote_candidate(Candidate::relayed(addr(4)));

        // host×host is non-relay; the other 3 involve at least one relay.
        assert_eq!(a.relay_pairs().count(), 3);
    }

    #[test]
    fn remote_is_relayed_matches_only_relay_kind_at_addr() {
        let mut a = PathAgent::new();
        a.add_remote_candidate(Candidate::host(addr(1)));
        a.add_remote_candidate(Candidate::relayed(addr(2)));

        assert!(!a.remote_is_relayed(addr(1)));
        assert!(a.remote_is_relayed(addr(2)));
        assert!(!a.remote_is_relayed(addr(3))); // unknown addr
    }

    #[test]
    fn duplicate_candidates_are_ignored() {
        let mut a = PathAgent::new();
        let c = Candidate::host(addr(1));
        a.add_local_candidate(c);
        a.add_local_candidate(c);
        a.add_remote_candidate(Candidate::host(addr(2)));
        assert_eq!(a.pairs().count(), 1);
    }

    #[test]
    fn observe_handshake_on_unknown_pair_is_noop() {
        let mut a = PathAgent::new();
        a.observe_handshake(addr(1), addr(2), Instant::now()); // does not panic
    }

    #[test]
    fn pairs_yields_local_remote_addresses() {
        let mut a = PathAgent::new();
        a.add_local_candidate(Candidate::host(addr(1)));
        a.add_remote_candidate(Candidate::host(addr(2)));

        let pairs: Vec<_> = a.pairs().collect();
        assert_eq!(pairs, vec![(addr(1), addr(2))]);
    }
}
