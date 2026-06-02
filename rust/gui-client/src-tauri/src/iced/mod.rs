//! Experimental iced-based GUI, gated behind the `experimental-gui` feature.
//!
//! An alternative front-end to the Tauri-based [`crate::gui`]. Keeping the tree
//! in the library (rather than the binary) lets a single `#[cfg]` on this module
//! gate the whole thing and its iced-only dependencies, instead of one `#[cfg]`
//! per submodule. Intra-tree references resolve through `crate::iced::…`.

pub mod assets;
pub mod integration;
pub mod state;
pub mod theme;
pub mod tray;
pub mod ui;

mod entry;

pub use entry::{Message, run};
