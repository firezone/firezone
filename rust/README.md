# Rust development guide

Firezone uses Rust for all data plane components in the product. This directory
contains all of the low-level networking immplementations related to STUN/TURN,
and the Rust-based Linux and Windows clients which are contained in this
directory.

## Developer Setup

Ensure that `rustup` is installed on your system and available in your `PATH`.
If not, follow the instructions for your platform.

Then, ensure you have the project toolchain installed with:

```sh
rustup show
```

Then installed necessary targets depending on your platform and component.
