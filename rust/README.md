# Rust development guide

Firezone uses Rust for all data plane components. This directory contains the
Linux and Windows clients, and low-level networking implementations related to
STUN/TURN.

We target the last stable release of Rust using [`rust-toolchain.toml`](./rust-toolchain.toml).
If you are using `rustup`, that is automatically handled for you.
Otherwise, ensure you have the latest stable version of Rust installed.
