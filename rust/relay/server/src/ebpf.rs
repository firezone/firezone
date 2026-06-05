#[cfg(all(target_os = "linux", feature = "ebpf"))]
#[path = "ebpf/linux.rs"]
mod platform;
#[cfg(not(all(target_os = "linux", feature = "ebpf")))]
#[path = "ebpf/stub.rs"]
mod platform;

pub use platform::Program;

#[derive(clap::ValueEnum, Debug, Clone, Copy)]
pub enum AttachMode {
    /// Attach in generic mode (SKB_MODE)
    Generic,
    /// Attach in driver mode (DRV_MODE)
    Driver,
}
