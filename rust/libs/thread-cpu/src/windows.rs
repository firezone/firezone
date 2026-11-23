use std::time::Duration;

use anyhow::{Context as _, Result};
use windows::{
    Win32::{
        Foundation::{ERROR_NO_MORE_FILES, FILETIME, HLOCAL, LocalFree},
        System::{
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First,
                Thread32Next,
            },
            Threading::{
                GetCurrentProcessId, GetThreadDescription, GetThreadTimes, OpenThread,
                THREAD_QUERY_LIMITED_INFORMATION,
            },
        },
    },
    core::Owned,
};

use crate::Thread;

pub fn threads() -> Result<Vec<Thread>> {
    // SAFETY: `CreateToolhelp32Snapshot` has no preconditions.
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) }
        .context("Failed to snapshot threads")?;
    // SAFETY: We own the handle `CreateToolhelp32Snapshot` returns.
    let snapshot = unsafe { Owned::new(snapshot) };
    // SAFETY: `GetCurrentProcessId` has no preconditions.
    let process = unsafe { GetCurrentProcessId() };
    let mut entry = THREADENTRY32 {
        dwSize: size_of::<THREADENTRY32>() as u32,
        ..Default::default()
    };
    let mut threads = Vec::new();

    // SAFETY: `snapshot` is valid and `entry` is valid for writes of its `dwSize`.
    unsafe { Thread32First(*snapshot, &mut entry) }.context("Failed to read first thread")?;

    loop {
        if entry.th32OwnerProcessID == process {
            threads.push(thread(entry.th32ThreadID)?);
        }

        // SAFETY: `snapshot` is valid and `entry` is valid for writes of its `dwSize`.
        match unsafe { Thread32Next(*snapshot, &mut entry) } {
            Ok(()) => {}
            Err(e) if e.code() == ERROR_NO_MORE_FILES.to_hresult() => break,
            Err(e) => return Err(e).context("Failed to read next thread"),
        }
    }

    Ok(threads)
}

fn thread(id: u32) -> Result<Thread> {
    // SAFETY: `OpenThread` has no preconditions.
    let handle = unsafe { OpenThread(THREAD_QUERY_LIMITED_INFORMATION, false, id) }
        .with_context(|| format!("Failed to open thread {id}"))?;
    // SAFETY: We own the handle `OpenThread` returns.
    let handle = unsafe { Owned::new(handle) };
    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();

    // SAFETY: `handle` is valid and all times are valid for writes.
    unsafe { GetThreadTimes(*handle, &mut creation, &mut exit, &mut kernel, &mut user) }
        .context("Failed to get thread times")?;

    // SAFETY: `handle` is valid.
    let description =
        unsafe { GetThreadDescription(*handle) }.context("Failed to get thread description")?;
    // SAFETY: `GetThreadDescription` returns a nul-terminated string.
    let name = unsafe { description.to_string() };
    // SAFETY: `GetThreadDescription` allocates the string with `LocalAlloc` and we no longer use it.
    unsafe { LocalFree(Some(HLOCAL(description.0.cast()))) };

    Ok(Thread {
        id: u64::from(id),
        name: name.context("Thread description is not UTF-16")?,
        cpu_time: duration(kernel) + duration(user),
    })
}

fn duration(time: FILETIME) -> Duration {
    let hundred_nanos = (u64::from(time.dwHighDateTime) << 32) | u64::from(time.dwLowDateTime);

    Duration::from_nanos(hundred_nanos * 100)
}
