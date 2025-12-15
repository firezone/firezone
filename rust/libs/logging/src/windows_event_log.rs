//! Windows Event Log layer for tracing.
//!
//! Provides a `tracing` layer that writes events to the Windows Event Log.
//!
//! Inspired by the [`tracing-layer-win-eventlog`](https://github.com/itsscb/tracing-layer-win-eventlog)
//! crate (MIT licensed).
//! Filters via `EVENTLOG_DIRECTIVES` env var (default: `info`), independent of `RUST_LOG`.
//!
//! ```ignore
//! tracing_subscriber::registry()
//!     .with(logging::windows_event_log::layer("MyApp")?)
//!     .init();
//! ```
//!
//! Event IDs: ERROR=1, WARN=2, INFO/DEBUG/TRACE=3 (supported by `EventCreate.exe`).
//!
//! Auto-registers the source on creation (requires admin). To register manually:
//! ```powershell
//! New-EventLog -LogName Application -Source "MyApp"
//! ```

#[cfg(windows)]
mod implementation;

#[cfg(windows)]
pub use implementation::*;

#[cfg(not(windows))]
mod stub;

#[cfg(not(windows))]
pub use stub::*;
