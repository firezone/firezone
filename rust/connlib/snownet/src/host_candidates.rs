use std::collections::BTreeMap;

use itertools::Itertools;
use str0m::{Candidate, CandidateKind};

/// A collection of host candidates.
///
/// We only allow a single host candidate per STUN server.
#[derive(Debug)]
pub struct HostCandidates<RId> {
    inner: BTreeMap<RId, Candidate>,
}

impl<RId> Default for HostCandidates<RId> {
    fn default() -> Self {
        Self {
            inner: Default::default(),
        }
    }
}

impl<RId> HostCandidates<RId>
where
    RId: Ord,
{
    pub fn insert(&mut self, server: RId, candidate: Candidate) -> bool {
        if candidate.kind() != CandidateKind::Host {
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
        let mut candidates = HostCandidates::default();

        let first_inserted = candidates.insert(1, host("2.2.2.2:80"));
        let second_inserted = candidates.insert(1, host("2.2.2.2:80"));

        assert!(first_inserted);
        assert!(!second_inserted);
    }

    #[test]
    fn only_returns_uniue_candidates() {
        let mut candidates = HostCandidates::default();

        candidates.insert(1, host("2.2.2.2:80"));
        candidates.insert(2, host("2.2.2.2:80"));

        assert_eq!(
            candidates.iter().collect::<Vec<_>>(),
            vec![host("2.2.2.2:80")]
        );
    }

    fn host(addr: &str) -> Candidate {
        Candidate::host(addr.parse().unwrap(), "udp").unwrap()
    }
}
