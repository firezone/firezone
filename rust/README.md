# Rust development guide

Firezone uses Rust for all data plane components. This directory
contains the Linux and Windows clients, and low-level networking implementations related to STUN/TURN.

## Developer Setup

Ensure that `rustup` is installed on your system and available in your `PATH`.
If not, follow the instructions for your platform.

Then, ensure you have the project toolchain installed with:

```sh
rustup show
```

Then installed necessary targets depending on your platform and component.
