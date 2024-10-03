# gtk-client

This crate houses a GTK+ 3 Client for Ubuntu 20.04, 22.04, and 24.04.

## Setup

1. [Install rustup](https://rustup.rs/)

## Building

`./build.sh`

This will install dev dependencies such as `libgtk-3-dev`, and the bundling tool `cargo-deb`.

## Installing

`sudo apt-get install target/debian/firezone-client-gui.deb`

## Platform support

- `aarch64` or `x86_64` CPU architecture
- Ubuntu 20.04 through 24.04 inclusive

Other distributions may work but are not officially supported.
