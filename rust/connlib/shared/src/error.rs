//! Error module.
use std::net::IpAddr;
use thiserror::Error;

/// Unified Result type to use across connlib.
pub type Result<T> = std::result::Result<T, ConnlibError>;

/// Unified error type to use across connlib.
#[derive(Error, Debug)]
pub enum ConnlibError {
    /// Standard IO error.
    #[error(transparent)]
    Io(#[from] std::io::Error),
    /// One of the stored resources isn't a valid CIDR/DNS.
    #[error("Invalid resource")]
    InvalidResource,
    /// Error regarding our own control protocol.
    #[error("Control plane protocol error. Unexpected messages or message order.")]
    ControlProtocolError,
    /// Glob for errors without a type.
    #[error("Other error: {0}")]
    Other(&'static str),
    /// No iface found
    #[error("No iface found")]
    NoIface,
    /// Expected file descriptor and none was found
    #[error("No filedescriptor")]
    NoFd,
    /// A panic occurred.
    #[error("Connlib panicked: {0}")]
    Panic(String),
    /// The task was cancelled
    #[error("Connlib task was cancelled")]
    Cancelled,
    /// A panic occurred with a non-string payload.
    #[error("Panicked with a non-string payload")]
    PanicNonStringPayload,
    /// Exhausted nat table
    #[error("exhausted nat")]
    ExhaustedNat,
    #[error(transparent)]
    UnsupportedProtocol(ip_packet::UnsupportedProtocol),
    // TODO: we might want to log some extra parameters on these failed translations
    /// Packet translation failed
    #[error("failed packet translation")]
    FailedTranslation,
    #[cfg(target_os = "windows")]
    #[error("Can't compute path for wintun.dll")]
    WintunDllPath,
    #[cfg(target_os = "windows")]
    #[error("Can't find AppData/Local folder")]
    CantFindLocalAppDataFolder,

    #[cfg(target_os = "linux")]
    #[error("Error while rewriting `/etc/resolv.conf`: {0}")]
    ResolvConf(anyhow::Error),

    #[error("Source not allowed: {src}")]
    SrcNotAllowed { src: IpAddr },

    #[error("Destination not allowed: {dst}")]
    DstNotAllowed { dst: IpAddr },

    // Error variants for `systemd-resolved` DNS control
    #[error("Failed to control system DNS with `resolvectl`")]
    ResolvectlFailed,

    #[error("connection to the portal failed: {0}")]
    PortalConnectionFailed(phoenix_channel::Error),
}
