//! A fast, randomly seeded [`BuildHasher`] for hash maps whose keys may be remotely influenced.

use std::hash::BuildHasher;

use foldhash::fast::{FixedState, FoldHasher};

/// Builds `foldhash` hashers with a seed drawn from `std`'s [`RandomState`](std::hash::RandomState).
///
/// `std` draws its keys from `getrandom`, which the fuzzer interposes to stay deterministic;
/// `foldhash`'s own random seed would bypass it.
#[derive(Clone, Debug)]
pub struct RandomState(FixedState);

impl Default for RandomState {
    fn default() -> Self {
        Self(FixedState::with_seed(
            std::hash::RandomState::new().hash_one(()),
        ))
    }
}

impl BuildHasher for RandomState {
    type Hasher = FoldHasher<'static>;

    #[inline]
    fn build_hasher(&self) -> Self::Hasher {
        self.0.build_hasher()
    }
}
