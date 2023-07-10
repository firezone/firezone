//! Error module.
use base64::{DecodeError, DecodeSliceError};
use boringtun::noise::errors::WireGuardError;
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
    /// Error while decoding a base64 value from a slice.
    #[error("There was an error while decoding a base64 value: {0}")]
    Base64DecodeSliceError(#[from] DecodeSliceError),
    /// Request error for websocket connection.
    #[error("Error forming request: {0}")]
    RequestError(#[from] tokio_tungstenite::tungstenite::http::Error),
    /// Error during websocket connection.
    #[error("Portal connection error: {0}")]
    PortalConnectionError(#[from] tokio_tungstenite::tungstenite::error::Error),
    /// Provided string was not formatted as a URL.
    #[error("Badly formatted URI")]
    UriError,
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
    /// No MTU found
    #[error("No MTU found")]
    NoMtu,
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
