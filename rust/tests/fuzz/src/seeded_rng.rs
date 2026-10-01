//! Seeds the random number generators the fuzz process draws from.
//!
//! `std` seeds every `HashMap`'s hasher once per thread from `getrandom`, so the
//! number of key comparisons a lookup makes, and with it the coverage an input
//! produces, differs between processes. Interposing the symbol replaces that
//! draw with a seeded stream; [`reset`] restarts it with the supplied seed.
//! The stream starts with seed zero before the first reset because
//! `std` draws at the first `HashMap`, which can happen before the first
//! iteration. `std` treats a short read as a failure and falls back to another
//! source, so the entire buffer has to be filled.
//!
//! `fastrand`'s thread-local generator seeds itself from the clock instead, out
//! of reach of the interposed symbol, and `is` draws STUN transaction IDs, the
//! ICE control tie breaker and the ICE credentials from it. [`reset`] therefore
//! rewinds that one too.

use std::ffi::{c_uint, c_void};
use std::sync::Mutex;

use rand::{Rng as _, SeedableRng as _, rngs::StdRng};

const INITIAL_SEED: u64 = 0;

static RNG: Mutex<Option<StdRng>> = Mutex::new(None);

/// Seeds the global entropy stream and the current thread's `fastrand` generator.
///
/// RNGs and hashers that have already cached their own state are not reset.
pub fn reset(seed: u64) {
    with_rng(|rng| *rng = StdRng::seed_from_u64(seed));

    fastrand::seed(seed);
}

/// # Safety
///
/// `buf` must be valid for writes of `buflen` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn getrandom(buf: *mut c_void, buflen: usize, _flags: c_uint) -> isize {
    if buf.is_null() || buflen == 0 {
        return 0;
    }

    // SAFETY: The caller guarantees `buf` is writable for `buflen` bytes.
    let out = unsafe { std::slice::from_raw_parts_mut(buf.cast::<u8>(), buflen) };

    with_rng(|rng| rng.fill_bytes(out));

    buflen as isize
}

fn with_rng<T>(op: impl FnOnce(&mut StdRng) -> T) -> T {
    let mut guard = RNG.lock().unwrap_or_else(|poisoned| poisoned.into_inner());

    op(guard.get_or_insert_with(|| StdRng::seed_from_u64(INITIAL_SEED)))
}
