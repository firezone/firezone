//! Error module.
use base64::DecodeError;
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
    /// Error while decoding a base64 value.
    #[error("There was an error while decoding a base64 value: {0}")]
    Base64DecodeError(#[from] DecodeError),
    /// Tried to access a resource which didn't exists.
    #[error("Tried to access an undefined resource")]
    UnknownResource,
    /// One of the stored resources isn't a valid CIDR/DNS.
    #[error("Invalid resource")]
    InvalidResource,
    /// Error regarding our own control protocol.
    #[error("Control plane protocol error. Unexpected messages or message order.")]
    ControlProtocolError,
    /// Glob for errors without a type.
    #[error("Other error: {0}")]
    Other(&'static str),
    #[cfg(target_os = "linux")]
    #[error(transparent)]
    NetlinkError(rtnetlink::Error),
    /// Io translation of netlink error
    /// The IO version is easier to interpret
    /// We maintain a different variant from the standard IO for this to keep more context
    #[error("IO netlink error: {0}")]
    NetlinkErrorIo(std::io::Error),
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
    /// Received connection details that might be stale
    #[error("Unexpected connection details")]
    UnexpectedConnectionDetails,
    /// Invalid destination for packet
    #[error("Invalid dest address")]
    InvalidDst,
    /// Connection is still being established, retry later
    #[error("Pending connection")]
    PendingConnection,
    #[cfg(target_os = "windows")]
    #[error("Windows error: {0}")]
    WindowsError(#[from] windows::core::Error),
    #[cfg(target_os = "windows")]
    #[error(transparent)]
    Wintun(#[from] wintun::Error),
    #[cfg(target_os = "windows")]
    #[error("Can't compute path for wintun.dll")]
    WintunDllPath,
    #[cfg(target_os = "windows")]
    #[error("Can't find AppData/Local folder")]
    CantFindLocalAppDataFolder,

    #[cfg(target_os = "linux")]
    #[error("Error while rewriting `/etc/resolv.conf`: {0}")]
    ResolvConf(anyhow::Error),

    #[error(transparent)]
    Snownet(#[from] snownet::Error),
    #[error("Detected non-allowed packet in channel from {0}")]
    UnallowedPacket(IpAddr),

    // Error variants for `systemd-resolved` DNS control
    #[error("Failed to control system DNS with `resolvectl`")]
    ResolvectlFailed,

    #[error("connection to the portal failed: {0}")]
    PortalConnectionFailed(phoenix_channel::Error),
}

#[cfg(target_os = "linux")]
impl From<rtnetlink::Error> for ConnlibError {
    fn from(err: rtnetlink::Error) -> Self {
        #[allow(clippy::wildcard_enum_match_arm)]
        match err {
            rtnetlink::Error::NetlinkError(err) => Self::NetlinkErrorIo(err.to_io()),
            err => Self::NetlinkError(err),
        }
    }
}

impl From<&'static str> for ConnlibError {
    fn from(e: &'static str) -> Self {
        ConnlibError::Other(e)
    }
}
