# gtk-client

This crate houses a GTK+ 3 Client for Ubuntu 20.04, 22.04, and 24.04.

## Setup

1. [Install rustup](https://rustup.rs/)
1. `sudo apt-get install libgtk-3-dev libxdo-dev`
1. `cargo install cargo-deb@2.7.0`

## Debugging

```bash
cargo build

# In one terminal
sudo -u root -g firezone-client target/debug/firezone-client-ipc run-debug

# Concurrently, in a 2nd terminal
target/debug/firezone-gui-client
```

## Building

`./build.sh`

This will install dev dependencies such as `libgtk-3-dev`, and the bundling tool `cargo-deb`.

## Installing

`sudo apt-get install target/debian/firezone-client-gui.deb`

## Platform support

- `aarch64` or `x86_64` CPU architecture
- Ubuntu 20.04 through 24.04 inclusive

Other distributions may work but are not officially supported.
