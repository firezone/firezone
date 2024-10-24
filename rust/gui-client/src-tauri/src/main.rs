//! The Firezone GUI client for Linux and Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod client;

fn main() -> anyhow::Result<()> {
    // Mitigates a bug in Ubuntu 22.04 - Under Wayland, some features of the window decorations like minimizing, closing the windows, etc., doesn't work unless you double-click the titlebar first.
    // SAFETY: No other thread is running yet
    unsafe {
        std::env::set_var("GDK_BACKEND", "x11");
    }

    client::run()
}
