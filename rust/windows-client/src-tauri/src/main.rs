//! The Firezone GUI client for Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

/// Output of `git describe` at compile time
/// e.g. `1.0.0-pre.4-20-ged5437c88-modified` where:
///
/// * `1.0.0-pre.4` is the most recent ancestor tag
/// * `20` is the number of commits since then
/// * `g` doesn't mean anything
/// * `ed5437c88` is the Git commit hash
/// * `-modified` is present if the working dir has any changes from that commit number
const GIT_VERSION: &str =
    git_version::git_version!(args = ["--always", "--dirty=-modified", "--tags"]);

fn main() -> anyhow::Result<()> {
    client::run()
}

#[cfg(target_family = "unix")]
mod client {
    pub(crate) fn run() -> anyhow::Result<()> {
        panic!("The Windows client does not compile on non-Windows platforms");
    }
}

#[cfg(target_os = "windows")]
mod client;
