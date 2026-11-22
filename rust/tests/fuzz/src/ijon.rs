// The AFL runtime defines this symbol weakly. Rust's IJON macros already emit
// the recording calls; this is the enable flag normally emitted by its LLVM pass.
#[used]
#[unsafe(no_mangle)]
static mut __afl_ijon_enabled: u32 = 1;

/// Prepares IJON before starting AFL's deferred forkserver.
pub fn prepare_runtime() {
    if std::env::var_os("__AFL_SHM_ID").is_none() {
        return;
    }

    unsafe extern "C" {
        static mut __afl_ijon_map_increased: u32;
    }

    // AFL++ 4.40c resets the negotiated map size after sanitizer coverage
    // initializes, but leaves this flag set. Rearm the expansion before
    // the deferred forkserver reports its map size. See the corresponding
    // runtime code at https://github.com/AFLplusplus/AFLplusplus/blob/e5a8ba39ecf97d05e286fdd4e01da96554dbf64f/instrumentation/afl-compiler-rt.o.c#L2312-L2340.
    unsafe { __afl_ijon_map_increased = 0 };
}
