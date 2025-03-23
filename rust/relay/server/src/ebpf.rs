#[cfg(target_os = "linux")]
#[path = "ebpf/linux.rs"]
mod platform;
#[cfg(not(target_os = "linux"))]
#[path = "ebpf/stub.rs"]
mod platform;

pub use platform::Program;
