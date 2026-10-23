//! Callgrind's client requests, which are no-ops when not running under Valgrind.
//!
//! The codes are from `callgrind.h`, the instruction sequence is the amd64 one from `valgrind.h`.

/// `VG_USERREQ_TOOL_BASE('C', 'T')`
const BASE: usize = (b'C' as usize) << 24 | (b'T' as usize) << 16;
const ZERO_STATS: usize = BASE + 1;
const TOGGLE_COLLECT: usize = BASE + 2;

/// Resets the counters of the current thread.
pub fn zero_stats() {
    request(ZERO_STATS);
}

/// Switches counting on if it is off and off if it is on.
pub fn toggle_collect() {
    request(TOGGLE_COLLECT);
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn request(code: usize) {
    let args = [code, 0, 0, 0, 0, 0];

    // SAFETY: Natively, the sequence rotates `rdi` by 128 bits, leaving it unchanged, and
    // exchanges `rbx` with itself. Valgrind recognises it and reads `args` instead.
    unsafe {
        std::arch::asm!(
            "rol rdi, 3",
            "rol rdi, 13",
            "rol rdi, 61",
            "rol rdi, 51",
            "xchg rbx, rbx",
            inout("rdx") 0_usize => _,
            in("rax") args.as_ptr(),
        );
    }
}

#[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
fn request(_: usize) {}
