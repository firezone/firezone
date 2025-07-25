use std::collections::BTreeMap;

use itertools::Itertools;
use str0m::{Candidate, CandidateKind};

/// A collection of server-reflexive candidates.
///
/// We only allow a single server-reflexive candidate per STUN server.
#[derive(Debug)]
pub struct ServerReflexiveCandidates<RId> {
    inner: BTreeMap<RId, Candidate>,
}

impl<RId> Default for ServerReflexiveCandidates<RId> {
    fn default() -> Self {
        Self {
            inner: Default::default(),
        }
    }
}

impl<RId> ServerReflexiveCandidates<RId>
where
    RId: Ord,
{
    pub fn insert(&mut self, server: RId, candidate: Candidate) -> bool {
        if candidate.kind() != CandidateKind::ServerReflexive {
            return false;
        }

        let existing = self.inner.insert(server, candidate.clone());

        existing.is_none_or(|existing| existing != candidate)
    }

    pub fn iter(&self) -> impl Iterator<Item = Candidate> {
        self.inner.values().unique().cloned()
    }

    pub fn clear(&mut self) {
        self.inner.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn returns_false_when_same_candidate_is_inserted() {
        let mut candidates = ServerReflexiveCandidates::default();

        let first_inserted = candidates.insert(1, srvlx("2.2.2.2:80", "1.1.1.1:80"));
        let second_inserted = candidates.insert(1, srvlx("2.2.2.2:80", "1.1.1.1:80"));

        assert!(first_inserted);
        assert!(!second_inserted);
    }

    #[test]
    fn only_returns_uniue_candidates() {
        let mut candidates = ServerReflexiveCandidates::default();

        candidates.insert(1, srvlx("2.2.2.2:80", "1.1.1.1:80"));
        candidates.insert(2, srvlx("2.2.2.2:80", "1.1.1.1:80"));

        assert_eq!(
            candidates.iter().collect::<Vec<_>>(),
            vec![srvlx("2.2.2.2:80", "1.1.1.1:80")]
        );
    }

    fn srvlx(addr: &str, base: &str) -> Candidate {
        Candidate::server_reflexive(addr.parse().unwrap(), base.parse().unwrap(), "udp").unwrap()
    }
}
