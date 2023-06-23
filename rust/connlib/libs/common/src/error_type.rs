//! Module that contains the Error-Type that hints how to handle an error to upper layers.
use macros::SwiftEnum;
/// This indicates whether the produced error is something recoverable or fatal.
/// Fata/Recoverable only indicates how to handle the error for the client.
///
/// Any of the errors in [ConnlibError][crate::error::ConnlibError] could be of any [ErrorType] depending the circumstance.
#[derive(Debug, Clone, Copy, SwiftEnum)]
pub enum ErrorType {
    /// Recoverable means that the session can continue
    /// e.g. Failed to send an SDP
    Recoverable,
    /// Fatal error means that the session should stop and start again,
    /// generally after user input, such as clicking connect once more.
    /// e.g. Max number of retries was reached when trying to connect to the portal.
    Fatal,
}

/// Auto generated enum by [SwiftEnum], all variants come from [ErrorType]
/// reference that for docs.
pub use swift_ffi::SwiftErrorType;
