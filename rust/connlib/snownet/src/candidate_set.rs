use std::collections::HashSet;

use itertools::Itertools;
use str0m::Candidate;

/// Custom "set" implementation for [`Candidate`]s based on a [`HashSet`] with an enforced ordering when iterating.
#[derive(Debug, Default)]
pub struct CandidateSet {
    inner: HashSet<Candidate>,
}

impl CandidateSet {
    #[expect(
        clippy::disallowed_methods,
        reason = "We don't care about the ordering."
    )]
    pub fn insert(&mut self, new: Candidate) -> bool {
        // Hashing a `Candidate` takes longer than checking a handful of entries using their `PartialEq` implementation.
        // This function is in the hot-path so it needs to be fast ...
        if self.inner.iter().any(|c| c == &new) {
            return false;
        }

        self.inner.insert(new)
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
