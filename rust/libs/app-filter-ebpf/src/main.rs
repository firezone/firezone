//! cgroup eBPF programs that keep unlisted applications out of the Firezone tunnel.
//!
//! Process identity is captured where it is cheap and reliable: the `sched_process_exec`
//! tracepoint sees the executable path, so it maintains the set of thread-group IDs
//! that currently run a listed executable. `sched_process_fork` carries the parent's
//! verdict over to its children and `sched_process_exit` retires IDs so a reused PID
//! never inherits a verdict. The socket-address hooks then only need the current TGID.
//!
//! Destinations are matched against the tunnel routes in LPM tries; the tunnel's DNS
//! servers are exempt because the system resolver sends those queries.

#![cfg_attr(target_arch = "bpf", no_std)]
#![cfg_attr(target_arch = "bpf", no_main)]

#[cfg(not(target_arch = "bpf"))]
fn main() {
    eprintln!("Error: This program is meant to be compiled as an eBPF program.");
    eprintln!("Use --target bpf or --target bpfel-unknown-none to compile for eBPF.");
    std::process::exit(1);
}

#[cfg(any(target_arch = "bpf", target_os = "linux"))]
mod filter;

#[cfg(target_arch = "bpf")]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[cfg(target_arch = "bpf")]
#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Apache-2.0\0\0\0";
