//! Enables IJON's runtime alongside Rust's built-in edge instrumentation.

// The AFL runtime defines this symbol weakly. Rust's IJON macros already emit
// the recording calls; this is the enable flag normally emitted by its LLVM pass.
#[cfg(fuzzing)]
#[used]
#[unsafe(no_mangle)]
static mut __afl_ijon_enabled: u32 = 1;

#[cfg(fuzzing)]
pub(crate) fn prepare_runtime() {
    if std::env::var_os("__AFL_SHM_ID").is_none() {
        return;
    }

    unsafe extern "C" {
        static mut __afl_ijon_map_increased: u32;
    }

    // AFL++ 4.40c resets the negotiated map size after sanitizer coverage
    // initializes, but leaves this flag set. Rearm the expansion before
    // the deferred forkserver reports its map size.
    unsafe { __afl_ijon_map_increased = 0 };
}
