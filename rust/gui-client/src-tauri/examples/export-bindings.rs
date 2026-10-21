//! Rewrites the committed TypeScript bindings from the current view types.
//!
//! `cargo run -p firezone-gui-client --example export-bindings`

use anyhow::Result;

fn main() -> Result<()> {
    firezone_gui_client::export_bindings()
}
