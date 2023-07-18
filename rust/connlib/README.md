# Connlib

Firezone's connectivity library shared by all clients.

## 🚧 Disclaimer 🚧

**NOTE**: This repository is undergoing heavy construction. You could say we're
_Building In The Open™_ in true open source spirit. Do not attempt to use
anything released here until this notice is removed. You have been warned.

## Building Connlib

Setting the `CONNLIB_MOCK` environment variable when packaging for Apple or Android will activate the `mock` feature flag, replacing connlib's normal connection logic with a mock for testing purposes.

1. You'll need a Rust toolchain installed if you don't have one already. We
   recommend following the instructions at https://rustup.rs.
1. `rustup show` will install all needed targets since they are added to `rust-toolchain.toml`.
1. Follow the relevant instructions for your platform:
1. [Apple](#apple)
1. [Android](#android)
1. [Linux](#linux)
1. [Windows](#windows)

### Apple

Connlib should build successfully with recent macOS and Xcode versions assuming
you have Rust installed. If not, open a PR with the notes you found.

### Android

### Linux

### Windows
