//! Callgrind's client requests, which are no-ops when not running under Valgrind.
//!
//! The codes are from `callgrind.h`, the instruction sequence is the amd64 one from `valgrind.h`.

/// `VG_USERREQ_TOOL_BASE('C', 'T')`
const BASE: usize = (b'C' as usize) << 24 | (b'T' as usize) << 16;
const ZERO_STATS: usize = BASE + 1;
const TOGGLE_COLLECT: usize = BASE + 2;

/// Runs `f` with counting off, except for what it runs in [`count`].
///
/// Discards what was counted before, such as AEAD calls during set-up that
/// `--toggle-collect` counted.
pub fn measure<T>(f: impl FnOnce() -> T) -> T {
    request(ZERO_STATS);

    toggled(f)
}

/// Runs `f` with counting on, inside [`measure`].
pub fn count<T>(f: impl FnOnce() -> T) -> T {
    toggled(f)
}

/// Runs `f` with counting switched from on to off or from off to on.
fn toggled<T>(f: impl FnOnce() -> T) -> T {
    request(TOGGLE_COLLECT);
    let result = f();
    request(TOGGLE_COLLECT);

    result
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
