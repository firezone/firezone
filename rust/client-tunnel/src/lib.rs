//! A library for the privileged tunnel process for a Linux Firezone Client
//!
//! This is built both standalone and as part of the GUI package. Building it
//! standalone is faster and skips all the GUI dependencies. We can use that build for
//! CLI use cases.
//!
//! Building it as a binary within the `gui-client` package allows the
//! Tauri deb bundler to pick it up easily.
//! Otherwise we would just make it a normal binary crate.

#[allow(clippy::print_stdout)]
pub fn run() {
    println!("Firezone Tunnel (library)");
}
