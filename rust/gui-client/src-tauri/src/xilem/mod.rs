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
//! NOTE: xilem renders through Vello/wgpu and currently has no software
//! renderer, so this UI requires a working GPU and cannot run headless (CI,
//! the gui-smoke-test, etc.). See `entry::run` for the list of pieces that are
//! still stubbed relative to the Tauri / iced clients.

pub mod integration;
pub mod state;
pub mod ui;

mod entry;

pub use entry::run;
