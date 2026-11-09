use app_filter_ebpf_shared::{EXE_PATH_LEN, ExePath, PRESENT};
use aya_ebpf::{
    EbpfContext as _,
    bindings::BPF_F_NO_PREALLOC,
    helpers::{bpf_get_current_pid_tgid, bpf_probe_read_kernel_str_bytes},
    macros::{cgroup_sock_addr, map, tracepoint},
    maps::{HashMap, LpmTrie, lpm_trie::Key},
    programs::{SockAddrContext, TracePointContext},
};

const ALLOW: i32 = 1;
const DENY: i32 = 0;

#[map]
static ALLOWED_EXES: HashMap<ExePath, u8> = HashMap::with_max_entries(256, 0);
#[map]
static ALLOWED_TGIDS: HashMap<u32, u8> = HashMap::with_max_entries(65_536, 0);
#[map]
static PROTECTED_V4: LpmTrie<[u8; 4], u8> = LpmTrie::with_max_entries(1024, BPF_F_NO_PREALLOC);
#[map]
static PROTECTED_V6: LpmTrie<[u8; 16], u8> = LpmTrie::with_max_entries(1024, BPF_F_NO_PREALLOC);
#[map]
static EXEMPT_V4: HashMap<[u8; 4], u8> = HashMap::with_max_entries(64, 0);
#[map]
static EXEMPT_V6: HashMap<[u8; 16], u8> = HashMap::with_max_entries(64, 0);

/// Offsets within the `sched:sched_process_exec` tracepoint record.
const EXEC_FILENAME_DATA_LOC: usize = 8;
/// Offset of `child_pid` within the `sched:sched_process_fork` tracepoint record.
const FORK_CHILD_PID: usize = 44;

#[tracepoint]
pub fn sched_process_exec(ctx: TracePointContext) -> u32 {
    let tgid = current_tgid();
    let mut path = ExePath::zeroed();

    // SAFETY: The offset is the documented location of the `filename` data-loc in this tracepoint.
    let Ok(data_loc) = (unsafe { ctx.read_at::<u32>(EXEC_FILENAME_DATA_LOC) }) else {
        return 0;
    };
    let offset = (data_loc & 0xffff) as usize;

    // SAFETY: The helper bounds the read to the buffer and returns an error for an unreadable source.
    let read = unsafe {
        bpf_probe_read_kernel_str_bytes(
            ctx.as_ptr().cast::<u8>().add(offset),
            &mut path.0[..EXE_PATH_LEN],
        )
    };
    if read.is_err() {
        // Prefer no verdict over a stale one: the process now runs an unknown image.
        let _ = ALLOWED_TGIDS.remove(&tgid);
        return 0;
    }

    // SAFETY: Map values are only read, never aliased mutably.
    let allowed = unsafe { ALLOWED_EXES.get(&path) }.is_some();
    if allowed {
        let _ = ALLOWED_TGIDS.insert(&tgid, &PRESENT, 0);
    } else {
        let _ = ALLOWED_TGIDS.remove(&tgid);
    }

    0
}

#[tracepoint]
pub fn sched_process_fork(ctx: TracePointContext) -> u32 {
    let parent = current_tgid();
    // SAFETY: Map values are only read, never aliased mutably.
    if unsafe { ALLOWED_TGIDS.get(&parent) }.is_none() {
        return 0;
    }

    // SAFETY: The offset is the documented location of `child_pid` in this tracepoint.
    let Ok(child) = (unsafe { ctx.read_at::<u32>(FORK_CHILD_PID) }) else {
        return 0;
    };
    let _ = ALLOWED_TGIDS.insert(&child, &PRESENT, 0);

    0
}

#[tracepoint]
pub fn sched_process_exit(_: TracePointContext) -> u32 {
    // Every thread's own ID is retired so an ID handed out at fork never outlives it.
    let pid = bpf_get_current_pid_tgid() as u32;
    let _ = ALLOWED_TGIDS.remove(&pid);

    0
}

#[cgroup_sock_addr(connect4)]
pub fn connect4(ctx: SockAddrContext) -> i32 {
    verdict_v4(&ctx)
}

#[cgroup_sock_addr(sendmsg4)]
pub fn sendmsg4(ctx: SockAddrContext) -> i32 {
    verdict_v4(&ctx)
}

#[cgroup_sock_addr(connect6)]
pub fn connect6(ctx: SockAddrContext) -> i32 {
    verdict_v6(&ctx)
}

#[cgroup_sock_addr(sendmsg6)]
pub fn sendmsg6(ctx: SockAddrContext) -> i32 {
    verdict_v6(&ctx)
}

#[inline(always)]
fn verdict_v4(ctx: &SockAddrContext) -> i32 {
    // SAFETY: The kernel hands us a valid `bpf_sock_addr` for the duration of the program.
    let dst = unsafe { (*ctx.sock_addr).user_ip4 }.to_ne_bytes();

    decide_v4(dst)
}

#[inline(always)]
fn verdict_v6(ctx: &SockAddrContext) -> i32 {
    // SAFETY: The kernel hands us a valid `bpf_sock_addr` for the duration of the program.
    let words = unsafe { (*ctx.sock_addr).user_ip6 };
    let mut dst = [0_u8; 16];
    dst[0..4].copy_from_slice(&words[0].to_ne_bytes());
    dst[4..8].copy_from_slice(&words[1].to_ne_bytes());
    dst[8..12].copy_from_slice(&words[2].to_ne_bytes());
    dst[12..16].copy_from_slice(&words[3].to_ne_bytes());

    let is_v4_mapped = dst[..10] == [0; 10] && dst[10] == 0xff && dst[11] == 0xff;
    if is_v4_mapped {
        return decide_v4([dst[12], dst[13], dst[14], dst[15]]);
    }

    // SAFETY: Map values are only read, never aliased mutably.
    if unsafe { EXEMPT_V6.get(&dst) }.is_some() {
        return ALLOW;
    }
    if PROTECTED_V6.get(&Key::new(128, dst)).is_none() {
        return ALLOW;
    }

    decide_app()
}

#[inline(always)]
fn decide_v4(dst: [u8; 4]) -> i32 {
    // SAFETY: Map values are only read, never aliased mutably.
    if unsafe { EXEMPT_V4.get(&dst) }.is_some() {
        return ALLOW;
    }
    if PROTECTED_V4.get(&Key::new(32, dst)).is_none() {
        return ALLOW;
    }

    decide_app()
}

#[inline(always)]
fn decide_app() -> i32 {
    // SAFETY: Map values are only read, never aliased mutably.
    if unsafe { ALLOWED_TGIDS.get(&current_tgid()) }.is_some() {
        return ALLOW;
    }

    DENY
}

#[inline(always)]
fn current_tgid() -> u32 {
    (bpf_get_current_pid_tgid() >> 32) as u32
}
