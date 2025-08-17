#[cfg(target_os = "linux")]
#[path = "ebpf/linux.rs"]
mod platform;
#[cfg(not(target_os = "linux"))]
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
