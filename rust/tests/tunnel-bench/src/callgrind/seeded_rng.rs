//! Seeds the random number generators the tunnel draws from, so that its hash maps and STUN
//! transaction IDs, and with them the instruction counts, are the same in every run.
//!
//! See the fuzzer's module of the same name for which generators these are.

use std::sync::Mutex;

use rand::{Rng as _, SeedableRng as _, rngs::StdRng};

static RNG: Mutex<Option<StdRng>> = Mutex::new(None);

pub fn reset() {
    with_rng(|rng| *rng = StdRng::seed_from_u64(0));
    fastrand::seed(0);
}

/// Fills `out` from the seeded generator, for a binary's `getrandom` override to call.
pub fn fill_bytes(out: &mut [u8]) {
    with_rng(|rng| rng.fill_bytes(out));
}

fn with_rng<T>(op: impl FnOnce(&mut StdRng) -> T) -> T {
    let mut guard = RNG.lock().unwrap_or_else(|poisoned| poisoned.into_inner());

    op(guard.get_or_insert_with(|| StdRng::seed_from_u64(0)))
}
