//! Error module.
use base64::{DecodeError, DecodeSliceError};
use boringtun::noise::errors::WireGuardError;
use std::net::IpAddr;
use thiserror::Error;
use tokio::task::JoinError;

/// Unified Result type to use across connlib.
pub type Result<T> = std::result::Result<T, ConnlibError>;

/// Unified error type to use across connlib.
#[derive(Error, Debug)]
pub enum ConnlibError {
    /// Standard IO error.
    #[error(transparent)]
    Io(#[from] std::io::Error),
    /// Standard IO error.
    #[error("Failed to roll over log file: {0}")]
    LogFileRollError(std::io::Error),
    /// Error while decoding a base64 value.
    #[error("There was an error while decoding a base64 value: {0}")]
    Base64DecodeError(#[from] DecodeError),
    /// Error while decoding a base64 value from a slice.
    #[error("There was an error while decoding a base64 value: {0}")]
    Base64DecodeSliceError(#[from] DecodeSliceError),
    /// Provided string was not formatted as a URL.
    #[error("Badly formatted URI")]
    UriError,
    /// Provided an unsupported uri string.
    #[error("Unsupported URI scheme: Must be http://, https://, ws:// or wss://")]
    UriScheme,
    /// Serde's serialize error.
    #[error(transparent)]
    SerializeError(#[from] serde_json::Error),
    /// Error when trying to establish connection between peers.
    #[error("Error while establishing connection between peers")]
    ConnectionEstablishError,
    /// Error related to wireguard protocol.
    #[error("Wireguard error")]
    WireguardError(WireGuardError),
    /// Expected an initialized runtime but there was none.
    #[error("Expected runtime to be initialized")]
    NoRuntime,
    /// Tried to access a resource which didn't exists.
    #[error("Tried to access an undefined resource")]
    UnknownResource,
    /// One of the stored resources isn't a valid CIDR/DNS.
    #[error("Invalid resource")]
    InvalidResource,
    /// Error regarding our own control protocol.
    #[error("Control plane protocol error. Unexpected messages or message order.")]
    ControlProtocolError,
    /// Error when reading system's interface
    #[error("Error while reading system's interface")]
    IfaceRead(std::io::Error),
    /// Glob for errors without a type.
    #[error("Other error: {0}")]
    Other(&'static str),
    /// Invalid tunnel name
    #[error("Invalid tunnel name")]
    InvalidTunnelName,
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
    /// No MTU found
    #[error("No MTU found")]
    NoMtu,
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
    /// Invalid phoenix channel reference
    #[error("Invalid phoenix channel reply reference")]
    InvalidReference,
    /// Invalid packet format
    #[error("Received badly formatted packet")]
    BadPacket,
    /// Tunnel is under load
    #[error("Under load")]
    UnderLoad,
    /// Invalid source address for peer
    #[error("Invalid source address")]
    InvalidSource,
    /// Invalid destination for packet
    #[error("Invalid dest address")]
    InvalidDst,
    /// Any parse error
    #[error("parse error")]
    ParseError,
    /// Connection is still being established, retry later
    #[error("Pending connection")]
    PendingConnection,
    #[error(transparent)]
    Uuid(#[from] uuid::Error),
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
    #[error("Token has expired")]
    TokenExpired,
    #[error("Too many concurrent gateway connection requests")]
    TooManyConnectionRequests,
    #[error("Channel connection closed by portal")]
    ClosedByPortal,
    #[error(transparent)]
    JoinError(#[from] JoinError),

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

impl From<WireGuardError> for ConnlibError {
    fn from(e: WireGuardError) -> Self {
        ConnlibError::WireguardError(e)
    }
}

impl From<&'static str> for ConnlibError {
    fn from(e: &'static str) -> Self {
        ConnlibError::Other(e)
    }
}
