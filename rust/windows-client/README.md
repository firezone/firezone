# windows-client

This crate houses the Firezone Windows client.

## Building

`cargo build` works from this directory

On Windows, in general:

```
cargo build --release --bin firezone-windows-client --target x86_64-pc-windows-msvc
```

The executable will be at `target/x86_64-pc-windows-msvc/release/firezone-windows-client.exe`.

## Cross-compiling

On Linux with the GNU target:

```
cargo build --release --bin firezone-windows-client --target x86_64-pc-windows-gnu
```

Running with WINE:

```
wine target/x86_64-pc-windows-gnu/release/firezone-windows-client.exe
```

(The GNU target is harder to set up on Windows, and the MSVC target is harder to set up on Linux)

## Running

TODO
