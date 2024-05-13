// This syntax is odd, but it helps `cargo-mutants` understand the platform-specific modules
#[cfg(target_os = "windows")]
#[path = "tunnel-wrapper/in_proc.rs"]
mod tunnel_wrapper_in_proc;

#[cfg(target_os = "linux")]
#[path = "tunnel-wrapper/ipc.rs"]
mod tunnel_wrapper_ipc;

#[cfg(target_os = "windows")]
pub(crate) use tunnel_wrapper_in_proc::*;

#[cfg(target_os = "linux")]
pub(crate) use tunnel_wrapper_ipc::*;

// TODO: Wrapper both tunnel wrappers with an enum
