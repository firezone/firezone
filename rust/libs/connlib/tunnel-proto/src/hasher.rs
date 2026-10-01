use std::hash::{BuildHasher as _, RandomState};

use foldhash::fast::FixedState;

/// Builds a `foldhash` hasher with a seed drawn from `std`'s [`RandomState`].
///
/// `std` draws its keys from `getrandom`, which the fuzzer interposes to stay
/// deterministic; `foldhash`'s own random seed would bypass it.
pub(crate) fn random_foldhash() -> FixedState {
    FixedState::with_seed(RandomState::new().hash_one(()))
}
