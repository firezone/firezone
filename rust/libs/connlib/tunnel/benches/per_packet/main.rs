#![allow(clippy::unwrap_used, clippy::wildcard_enum_match_arm)]

#[cfg(target_os = "linux")]
mod event_loop;

fn main() {
    divan::main()
}
