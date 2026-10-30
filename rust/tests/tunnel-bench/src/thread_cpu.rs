//! The CPU time of every thread of this process, read without hooks in their loops.

use std::time::Duration;

/// Returns the CPU time each thread of this process has used so far, by thread name.
pub fn thread_cpu_times() -> Vec<(String, Duration)> {
    cfg_select! {
        target_os = "linux" => { linux::thread_cpu_times() }
        target_os = "macos" => { macos::thread_cpu_times() }
        windows => { windows::thread_cpu_times() }
        _ => { Vec::new() }
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use std::time::Duration;

    pub fn thread_cpu_times() -> Vec<(String, Duration)> {
        let Ok(tasks) = std::fs::read_dir("/proc/self/task") else {
            return Vec::new();
        };

        tasks
            .filter_map(Result::ok)
            .filter_map(|task| {
                let name = std::fs::read_to_string(task.path().join("comm")).ok()?;
                let schedstat = std::fs::read_to_string(task.path().join("schedstat")).ok()?;
                let nanos = schedstat.split(' ').next()?.parse::<u64>().ok()?;

                Some((name.trim_end().to_owned(), Duration::from_nanos(nanos)))
            })
            .collect()
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::CStr;
    use std::mem::{MaybeUninit, size_of};
    use std::time::Duration;

    use libc::{
        KERN_SUCCESS, THREAD_BASIC_INFO, THREAD_BASIC_INFO_COUNT, mach_msg_type_number_t,
        mach_port_t, thread_act_array_t, thread_basic_info, time_value_t,
    };

    unsafe extern "C" {
        static mach_task_self_: mach_port_t;
        fn mach_port_deallocate(task: mach_port_t, name: mach_port_t) -> libc::kern_return_t;
    }

    pub fn thread_cpu_times() -> Vec<(String, Duration)> {
        // SAFETY: The port of the calling task, set once at process start.
        let task = unsafe { mach_task_self_ };
        let mut threads: thread_act_array_t = std::ptr::null_mut();
        let mut count: mach_msg_type_number_t = 0;
        // SAFETY: Both out-pointers are valid and the array is deallocated below.
        if unsafe { libc::task_threads(task, &mut threads, &mut count) } != KERN_SUCCESS {
            return Vec::new();
        }
        // SAFETY: `task_threads` returned `count` thread ports starting at `threads`.
        let ports = unsafe { std::slice::from_raw_parts(threads, count as usize) };

        let times = ports
            .iter()
            .filter_map(|&thread| Some((name(thread)?, cpu_time(thread)?)))
            .collect();

        for &thread in ports {
            // SAFETY: Releases the reference `task_threads` gave us on this port.
            unsafe { mach_port_deallocate(task, thread) };
        }
        // SAFETY: Frees the array `task_threads` allocated in our address space.
        unsafe {
            libc::vm_deallocate(
                task,
                threads as libc::vm_address_t,
                count as usize * size_of::<mach_port_t>(),
            )
        };

        times
    }

    fn name(thread: mach_port_t) -> Option<String> {
        // SAFETY: Returns null for threads not created through pthread.
        let pthread = unsafe { libc::pthread_from_mach_thread_np(thread) };
        if pthread == 0 {
            return None;
        }
        let mut buffer = [0_i8; 64];
        // SAFETY: The buffer is valid for its given length and gets NUL-terminated.
        if unsafe { libc::pthread_getname_np(pthread, buffer.as_mut_ptr(), buffer.len()) } != 0 {
            return None;
        }

        Some(
            CStr::from_bytes_until_nul(&buffer.map(|b| b as u8))
                .ok()?
                .to_string_lossy()
                .into_owned(),
        )
    }

    fn cpu_time(thread: mach_port_t) -> Option<Duration> {
        let mut info = MaybeUninit::<thread_basic_info>::uninit();
        let mut count = THREAD_BASIC_INFO_COUNT;
        // SAFETY: `info` has room for `count` integers, which the call fills before returning.
        let result = unsafe {
            libc::thread_info(
                thread,
                THREAD_BASIC_INFO as _,
                info.as_mut_ptr().cast(),
                &mut count,
            )
        };
        if result != KERN_SUCCESS {
            return None;
        }
        // SAFETY: The call succeeded, so the struct is initialised.
        let info = unsafe { info.assume_init() };

        Some(duration(info.user_time) + duration(info.system_time))
    }

    fn duration(time: time_value_t) -> Duration {
        Duration::from_secs(time.seconds as u64) + Duration::from_micros(time.microseconds as u64)
    }
}

#[cfg(windows)]
mod windows {
    use std::time::Duration;

    use windows::Win32::Foundation::{CloseHandle, FILETIME, HANDLE, HLOCAL, LocalFree};
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
    };
    use windows::Win32::System::Threading::{
        GetCurrentProcessId, GetThreadDescription, GetThreadTimes, OpenThread,
        THREAD_QUERY_LIMITED_INFORMATION,
    };

    pub fn thread_cpu_times() -> Vec<(String, Duration)> {
        // SAFETY: A snapshot of all threads in the system; the process ID is ignored for threads.
        let Ok(snapshot) = (unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) }) else {
            return Vec::new();
        };
        // SAFETY: Returns the ID of the calling process.
        let pid = unsafe { GetCurrentProcessId() };

        let mut entry = THREADENTRY32 {
            dwSize: size_of::<THREADENTRY32>() as u32,
            ..Default::default()
        };
        let mut times = Vec::new();
        // SAFETY: `entry` is a valid, sized entry and the snapshot is open until closed below.
        let mut next = unsafe { Thread32First(snapshot, &mut entry) };
        while next.is_ok() {
            if entry.th32OwnerProcessID == pid
                && let Some(time) = thread_time(entry.th32ThreadID)
            {
                times.push(time);
            }
            // SAFETY: Same as for `Thread32First`.
            next = unsafe { Thread32Next(snapshot, &mut entry) };
        }
        // SAFETY: The snapshot handle is open and no longer used.
        let _ = unsafe { CloseHandle(snapshot) };

        times
    }

    fn thread_time(thread_id: u32) -> Option<(String, Duration)> {
        // SAFETY: Opens a handle to a thread of this process, closed below.
        let handle =
            unsafe { OpenThread(THREAD_QUERY_LIMITED_INFORMATION, false, thread_id) }.ok()?;
        let time = name(handle).and_then(|name| Some((name, cpu_time(handle)?)));
        // SAFETY: The handle was opened above and is no longer used.
        let _ = unsafe { CloseHandle(handle) };

        time
    }

    fn name(handle: HANDLE) -> Option<String> {
        // SAFETY: The handle is open with query access; the returned string is freed below.
        let description = unsafe { GetThreadDescription(handle) }.ok()?;
        // SAFETY: The string is NUL-terminated and owned by us until freed.
        let name = unsafe { description.to_string() }.ok();
        // SAFETY: `GetThreadDescription` allocates the string with `LocalAlloc`.
        unsafe { LocalFree(Some(HLOCAL(description.as_ptr().cast()))) };

        name.filter(|name| !name.is_empty())
    }

    /// Returns the kernel plus user time of a thread.
    ///
    /// Windows accounts thread times per clock tick (about 16 ms), so short-lived threads read as
    /// zero, and only totals over many ticks are meaningful.
    fn cpu_time(handle: HANDLE) -> Option<Duration> {
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        // SAFETY: All out-pointers are valid for the duration of the call.
        unsafe { GetThreadTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) }.ok()?;

        Some(duration(kernel) + duration(user))
    }

    fn duration(time: FILETIME) -> Duration {
        let ticks = (u64::from(time.dwHighDateTime) << 32) | u64::from(time.dwLowDateTime);

        Duration::from_nanos(ticks * 100)
    }
}
