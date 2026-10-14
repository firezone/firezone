#![allow(
    clippy::print_stderr,
    clippy::unwrap_used,
    clippy::wildcard_enum_match_arm
)]

#[cfg(target_os = "linux")]
mod event_loop;
mod setup;
mod state;

fn main() {
    divan::main()
}
