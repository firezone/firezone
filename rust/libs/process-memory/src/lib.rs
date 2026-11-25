//! How much memory the current process uses, as the platform counts it when enforcing memory limits.

use anyhow::Result;

#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn usage() -> Result<u64> {
    use anyhow::Context as _;

    let statm =
        std::fs::read_to_string("/proc/self/statm").context("Failed to read `/proc/self/statm`")?;
    let resident_pages = statm
        .split_whitespace()
        .nth(1)
        .context("`/proc/self/statm` has no resident field")?
        .parse::<u64>()
        .context("Failed to parse resident pages")?;

    // SAFETY: `sysconf` has no preconditions.
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    let page_size = u64::try_from(page_size).context("Failed to get page size")?;

    Ok(resident_pages * page_size)
}

#[cfg(target_vendor = "apple")]
pub fn usage() -> Result<u64> {
    use mach2::{
        kern_return::KERN_SUCCESS,
        message::mach_msg_type_number_t,
        task::task_info,
        task_info::{TASK_VM_INFO, task_vm_info},
        traps::mach_task_self,
        vm_types::natural_t,
    };

    let mut info = task_vm_info::default();
    let mut count = (size_of::<task_vm_info>() / size_of::<natural_t>()) as mach_msg_type_number_t;

    // SAFETY: `info` is valid for writes of `count` `natural_t`s, the most `task_info` writes.
    let result = unsafe {
        task_info(
            mach_task_self(),
            TASK_VM_INFO,
            (&raw mut info).cast(),
            &mut count,
        )
    };
    anyhow::ensure!(result == KERN_SUCCESS, "`task_info` failed: {result}");

    Ok(info.phys_footprint)
}

#[cfg(windows)]
pub fn usage() -> Result<u64> {
    use anyhow::Context as _;
    use windows::Win32::System::{
        ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS_EX},
        Threading::GetCurrentProcess,
    };

    let mut counters = PROCESS_MEMORY_COUNTERS_EX::default();

    // SAFETY: `counters` is valid for writes of the size we pass and `GetCurrentProcess` returns a pseudo-handle that needs no closing.
    unsafe {
        GetProcessMemoryInfo(
            GetCurrentProcess(),
            (&raw mut counters).cast(),
            size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32,
        )
    }
    .context("Failed to get process memory info")?;

    Ok(counters.PrivateUsage as u64)
}
