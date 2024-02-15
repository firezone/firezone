//! Error module.
use base64::{DecodeError, DecodeSliceError};
use boringtun::noise::errors::WireGuardError;
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
    /// Request error for websocket connection.
    #[error("Error forming request: {0}")]
    RequestError(#[from] tokio_tungstenite::tungstenite::http::Error),
    /// Websocket heartbeat timedout
    #[error("Websocket heartbeat timedout")]
    WebsocketTimeout(#[from] tokio_stream::Elapsed),
    /// Error during websocket connection.
    #[error("Portal connection error: {0}")]
    PortalConnectionError(#[from] tokio_tungstenite::tungstenite::error::Error),
    /// Provided string was not formatted as a URL.
    #[error("Badly formatted URI")]
    UriError,
    /// Provided an unsupported uri string.
    #[error("Unsupported URI scheme: Must be http://, https://, ws:// or wss://")]
    UriScheme,
    /// Serde's serialize error.
    #[error(transparent)]
    SerializeError(#[from] serde_json::Error),
    /// Webrtc error
    #[error("ICE-related error: {0}")]
    IceError(#[from] webrtc::Error),
    /// Webrtc error regarding data channel.
    #[error("ICE-data error: {0}")]
    IceDataError(#[from] webrtc::data::Error),
    /// Error while sending through an async channelchannel.
    #[error("Error sending message through an async channel")]
    SendChannelError,
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
    #[error("`on_set_interface_config` failed: {0}")]
    OnSetInterfaceConfigFailed(String),
    #[error("`on_tunnel_ready` failed: {0}")]
    OnTunnelReadyFailed(String),
    #[error("`on_add_route` failed: {0}")]
    OnAddRouteFailed(String),
    #[error("`on_remove_route` failed: {0}")]
    OnRemoveRouteFailed(String),
    #[error("`on_update_resources` failed: {0}")]
    OnUpdateResourcesFailed(String),
    #[error("`get_system_default_resolvers` failed: {0}")]
    GetSystemDefaultResolverFailed(String),
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
    #[error("Panicked: {0}")]
    Panic(String),
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
    /// DNS lookup error
    #[error("Error with the DNS fallback lookup")]
    DNSFallback(#[from] hickory_resolver::error::ResolveError),
    #[error("Error with the DNS fallback lookup")]
    DNSFallbackKind(#[from] hickory_resolver::error::ResolveErrorKind),
    #[error("DNS proto error")]
    DnsProtoError(#[from] hickory_resolver::proto::error::ProtoError),
    /// Connection is still being stablished, retry later
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

    // Error variants for `/etc/resolv.conf` DNS control
    #[error("Failed to read `resolv.conf`: {0}")]
    ReadResolvConf(std::io::Error),
    #[error("Failed to parse `resolv.conf`")]
    ParseResolvConf,
    #[error("Failed to backup `resolv.conf`: {0}")]
    WriteResolvConfBackup(std::io::Error),
    #[error("Failed to rewrite `resolv.conf`: {0}")]
    RewriteResolvConf(std::io::Error),

    // Error variants for `systemd-resolved` DNS control
    #[error("`resolvectl dns` should have run: {0}")]
    ResolvectlDnsDidntRun(std::io::Error),
    #[error("`resolvectl dns` should have succeeded: {0}")]
    ResolvectlDnsFailed(std::process::ExitStatus),
    #[error("`resolvectl domain` should have run: {0}")]
    ResolvectlDomainDidntRun(std::io::Error),
    #[error("`resolvectl domain` should have succeeded: {0}")]
    ResolvectlDomainFailed(std::process::ExitStatus),
}

impl ConnlibError {
    pub fn is_http_client_error(&self) -> bool {
        matches!(
            self,
            Self::PortalConnectionError(tokio_tungstenite::tungstenite::error::Error::Http(e))
            if e.status().is_client_error()
        )
    }

    /// Whether this error is fatal to the underlying connection.
    pub fn is_fatal_connection_error(&self) -> bool {
        if let Self::WireguardError(e) = self {
            return matches!(
                e,
                WireGuardError::ConnectionExpired | WireGuardError::NoCurrentSession
            );
        }

        if let Self::IceDataError(e) = self {
            return matches!(
                e,
                webrtc::data::Error::ErrStreamClosed
                    | webrtc::data::Error::Sctp(webrtc::sctp::Error::ErrStreamClosed)
            );
        }

        false
    }
}

#[cfg(target_os = "linux")]
impl From<rtnetlink::Error> for ConnlibError {
    fn from(err: rtnetlink::Error) -> Self {
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

impl<T> From<tokio::sync::mpsc::error::SendError<T>> for ConnlibError {
    fn from(_: tokio::sync::mpsc::error::SendError<T>) -> Self {
        ConnlibError::SendChannelError
    }
}

impl From<futures::channel::mpsc::SendError> for ConnlibError {
    fn from(_: futures::channel::mpsc::SendError) -> Self {
        ConnlibError::SendChannelError
    }
}
