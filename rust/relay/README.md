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

Two environment variables need to be set for the server to be operational:

- `RELAY_LISTEN_IP4_ADDR`: The IPv4 address of a local interface we should bind to. Must not be a wildcard address.
- `RELAY_PUBLIC_IP4_ADDR`: The public IPv4 address of the above interface.

## Design

The relay is designed in a sans-IO fashion, meaning the core components do not cause side effects but operate as pure, synchronous state machines.
They take in data and emit commands: wake me at this point in time, send these bytes to this peer, etc.

This allows us to very easily unit-test all kinds of scenarios because all inputs are simple values.

The main server runs in a single task and spawns one additional task for each allocation.
Incoming data that needs to be relayed is forwarded to the main task where it gets authenticated and relayed on success.
