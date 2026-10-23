//! Seeds the random number generators the tunnel draws from, so that its hash maps and STUN
//! transaction IDs, and with them the instruction counts, are the same in every run.
//!
//! See the fuzzer's module of the same name for which generators these are.

use std::ffi::{c_uint, c_void};
use std::sync::Mutex;

use rand::{Rng as _, SeedableRng as _, rngs::StdRng};

static RNG: Mutex<Option<StdRng>> = Mutex::new(None);

pub fn reset() {
    with_rng(|rng| *rng = StdRng::seed_from_u64(0));
    fastrand::seed(0);
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

    op(guard.get_or_insert_with(|| StdRng::seed_from_u64(0)))
}
