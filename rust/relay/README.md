# relay

This crate houses a minimalistic STUN & TURN server.

## Features

We aim to support the following feature set:

- STUN binding requests
- TURN allocate requests
- TURN refresh requests
- TURN channel bind requests
- TURN channel data requests

Relaying of data through other means such as DATA frames is not supported.

## Building

You can build the server using: `cargo build --release --bin relay`

## Running

For a detailed help text and available configuration options, run `cargo run --bin relay -- --help`.
All command-line options can be overridden using environment variables.
Those variables are listed in the `--help` output at the bottom of each command.

The relay listens on port `3478`.
This is the standard port for STUN/TURN and not configurable.
Additionally, the relay needs to have access to the port range `49152` - `65535` for the allocations.

## Design

The relay is designed in a sans-IO fashion, meaning the core components do not cause side effects but operate as pure, synchronous state machines.
They take in data and emit commands: wake me at this point in time, send these bytes to this peer, etc.

This allows us to very easily unit-test all kinds of scenarios because all inputs are simple values.

The main server runs in a single task and spawns one additional task for each allocation.
Incoming data that needs to be relayed is forwarded to the main task where it gets authenticated and relayed on success.
