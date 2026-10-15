//! A fast, randomly seeded [`BuildHasher`] for hash maps whose keys may be remotely influenced.

use std::{
    hash::{BuildHasher, RandomState},
    sync::LazyLock,
};

use foldhash::{
    SharedSeed,
    fast::{FoldHasher, SeedableRandomState},
};

/// Mixed into every input; it must be secret, otherwise inputs can be chosen to collide regardless of the per-hasher seed.
static SHARED_SEED: LazyLock<SharedSeed> =
    LazyLock::new(|| SharedSeed::from_u64(RandomState::new().hash_one(())));

/// Builds `foldhash` hashers whose per-hasher and shared seeds are drawn from `std`'s [`RandomState`].
///
/// `std` draws its keys from `getrandom`, which the fuzzer interposes to stay deterministic;
/// `foldhash`'s own random seeds would bypass it.
#[derive(Clone, Debug)]
pub struct FastRandomState(SeedableRandomState);

impl Default for FastRandomState {
    fn default() -> Self {
        Self(SeedableRandomState::with_seed(
            RandomState::new().hash_one(()),
            LazyLock::force(&SHARED_SEED),
        ))
    }
}

impl BuildHasher for FastRandomState {
    type Hasher = FoldHasher<'static>;

    #[inline]
    fn build_hasher(&self) -> Self::Hasher {
        self.0.build_hasher()
    }
}
