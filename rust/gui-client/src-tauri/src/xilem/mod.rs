//! Experimental xilem-based GUI, gated behind the `experimental-xilem-gui`
//! feature. This is a parallel sibling to [`crate::iced`]: a second
//! alternative front-end to the Tauri-based [`crate::gui`], built to compare
//! xilem against iced on the same shared [`crate::controller::Controller`]
//! seam.
//!
//! Like the iced tree, keeping this in the library (rather than the binary)
//! lets a single `#[cfg]` on this module gate the whole thing plus the `xilem`
//! dependency. Intra-tree references resolve through `crate::xilem::…`.
//!
//! Wired up so far: the five screens (overview / general+advanced settings /
//! diagnostics / about), sign-in/out and settings persistence through the
//! Controller, the system [`tray`] (clicks + live icon/menu updates), and
//! async log export.
//!
//! NOTE: xilem renders through Vello/wgpu and currently has no software
//! renderer, so this UI requires a working GPU and cannot run headless (CI,
//! the gui-smoke-test, etc.).
//!
//! Remaining gaps relative to the Tauri / iced clients — all rooted in xilem
//! 0.4's high-level API rather than missing wiring:
//!
//! * **Daemon window lifecycle.** `Xilem::new_simple` runs a single window
//!   that exits the process on close; there is no close-to-tray. xilem only
//!   creates/destroys windows (no hide), and the async bridge `worker` — which
//!   owns the Controller and tray-event pump — lives *inside* a window's view
//!   tree, so it cannot outlive the window. A true daemon (tray alive with no
//!   window, reopened from a tray click) needs the Controller + tray decoupled
//!   onto a background runtime plus the low-level `into_driver_and_windows`
//!   event loop to inject "open window" events, since the high-level API
//!   exposes no app-level view or external state-injection path.
//! * **Theming / assets.** Stock Masonry widgets only — no brand colours
//!   (xilem 0.4's `label` has no colour setter; only `prose` does), logo /
//!   SVG icons, bundled fonts, or animated toggles.

pub mod integration;
pub mod state;
pub mod tray;
pub mod ui;

mod entry;

pub use entry::run;
