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

    #[error("connection to the portal failed: {0}")]
    PortalConnectionFailed(phoenix_channel::Error),
}
