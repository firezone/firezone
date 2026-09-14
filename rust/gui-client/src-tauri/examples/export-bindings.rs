//! Rewrites the committed TypeScript bindings from the current view types.
//!
//! `cargo run -p firezone-gui-client --example export-bindings`

fn main() -> anyhow::Result<()> {
    firezone_gui_client::export_bindings()
}
