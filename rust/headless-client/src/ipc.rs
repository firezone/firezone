#[cfg(target_os = "linux")]
#[path = "ipc/linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "ipc/windows.rs"]
pub mod platform;

pub use platform::{connect_to_service, ClientStream};
pub(crate) use platform::{Server, ServerStream};
