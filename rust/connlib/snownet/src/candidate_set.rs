use std::collections::HashSet;

use itertools::Itertools;
use str0m::Candidate;

/// Custom "set" implementation for [`Candidate`]s based on a [`HashSet`] with an enforced ordering when iterating.
#[derive(Debug, Default)]
pub struct CandidateSet {
    inner: HashSet<Candidate>,
}

impl CandidateSet {
    pub fn insert(&mut self, c: Candidate) -> bool {
        self.inner.insert(c)
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "We are guaranteeing a stable ordering"
    )]
    pub fn iter(&self) -> impl Iterator<Item = &Candidate> {
        self.inner.iter().sorted_by_key(|c| c.prio())
    }
}
