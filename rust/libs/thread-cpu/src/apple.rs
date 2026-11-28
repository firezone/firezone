use std::{ffi::CStr, time::Duration};

use anyhow::{Context as _, Result};
use mach2::{
    kern_return::KERN_SUCCESS,
    mach_port::mach_port_deallocate,
    mach_types::{thread_act_array_t, thread_act_t},
    message::mach_msg_type_number_t,
    task::task_threads,
    traps::mach_task_self,
    vm::mach_vm_deallocate,
};

use crate::Thread;

pub fn threads() -> Result<Vec<Thread>> {
    // SAFETY: `mach_task_self` has no preconditions.
    let task = unsafe { mach_task_self() };
    let mut list: thread_act_array_t = std::ptr::null_mut();
    let mut count: mach_msg_type_number_t = 0;

    // SAFETY: `list` and `count` are valid for writes.
    let result = unsafe { task_threads(task, &mut list, &mut count) };
    anyhow::ensure!(result == KERN_SUCCESS, "`task_threads` failed: {result}");

    // SAFETY: `task_threads` succeeded, so `list` points to `count` thread ports.
    let ports = unsafe { std::slice::from_raw_parts(list, count as usize) };
    let threads = ports.iter().filter_map(|port| thread(*port).ok()).collect();

    for port in ports {
        // SAFETY: `task_threads` gave us a send right to each port, which we no longer use.
        unsafe { mach_port_deallocate(task, *port) };
    }

    // SAFETY: `task_threads` allocated `list` in our address space and we no longer use it.
    unsafe {
        mach_vm_deallocate(
            task,
            list as u64,
            u64::from(count) * size_of::<thread_act_t>() as u64,
        )
    };

    Ok(threads)
}

fn thread(port: thread_act_t) -> Result<Thread> {
    let mut info = libc::thread_extended_info {
        pth_user_time: 0,
        pth_system_time: 0,
        pth_cpu_usage: 0,
        pth_policy: 0,
        pth_run_state: 0,
        pth_flags: 0,
        pth_sleep_time: 0,
        pth_curpri: 0,
        pth_priority: 0,
        pth_maxpriority: 0,
        pth_name: [0; libc::MAXTHREADNAMESIZE],
    };
    let mut count = libc::THREAD_EXTENDED_INFO_COUNT;

    // SAFETY: `info` is valid for writes of `count` `integer_t`s, the most `thread_info` writes.
    let result = unsafe {
        libc::thread_info(
            port,
            libc::THREAD_EXTENDED_INFO as libc::thread_flavor_t,
            (&raw mut info).cast(),
            &mut count,
        )
    };
    anyhow::ensure!(result == KERN_SUCCESS, "`thread_info` failed: {result}");

    let name = info.pth_name.map(|c| c as u8);
    let name = CStr::from_bytes_until_nul(&name)
        .context("Thread name is not nul-terminated")?
        .to_string_lossy()
        .into_owned();

    Ok(Thread {
        id: u64::from(port),
        name,
        cpu_time: Duration::from_nanos(info.pth_user_time + info.pth_system_time),
    })
}
