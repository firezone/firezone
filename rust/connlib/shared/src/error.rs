//! Error module.
use thiserror::Error;

/// Unified Result type to use across connlib.
pub type Result<T> = std::result::Result<T, ConnlibError>;

/// Unified error type to use across connlib.
#[derive(Error, Debug)]
pub enum ConnlibError {
    /// Standard IO error.
    #[error(transparent)]
    Io(#[from] std::io::Error),
    /// A panic occurred.
    #[error("Connlib panicked: {0}")]
    Panic(String),
    /// The task was cancelled
    #[error("Connlib task was cancelled")]
    Cancelled,
    /// A panic occurred with a non-string payload.
    #[error("Panicked with a non-string payload")]
    PanicNonStringPayload,
    #[cfg(target_os = "windows")]
    #[error("Can't compute path for wintun.dll")]
    WintunDllPath,
    #[cfg(target_os = "windows")]
    #[error("Can't find AppData/Local folder")]
    CantFindLocalAppDataFolder,

    #[cfg(target_os = "linux")]
    #[error("Error while rewriting `/etc/resolv.conf`: {0}")]
    ResolvConf(anyhow::Error),

    // Error variants for `systemd-resolved` DNS control
    #[error("Failed to control system DNS with `resolvectl`")]
    ResolvectlFailed,

    #[error("connection to the portal failed: {0}")]
    PortalConnectionFailed(phoenix_channel::Error),
}
