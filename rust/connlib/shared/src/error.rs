//! Error module.
use base64::DecodeError;
use std::{collections::HashSet, net::IpAddr};
use thiserror::Error;

/// Unified Result type to use across connlib.
pub type Result<T, E = ConnlibError> = std::result::Result<T, E>;

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
    /// Invalid destination for packet
    #[error("Invalid dest address")]
    InvalidDst,
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

    #[error("source: {src}; allowed_ips: {allowed_ips:?}")]
    UnallowedPacket {
        src: IpAddr,
        allowed_ips: HashSet<IpAddr>,
    },

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
