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

You can build the relay using: `cargo build --release --bin firezone-relay`

You should then find a binary in `target/release/firezone-relay`.

## Running

To run the relay:

```
firezone-relay --portal_token <portal_token>
```

where `portal_token` is the token shown when creating a Relay in the Firezone
admin portal.

For an up-to-date documentation on the available configurations options and a
detailed help text, run `cargo run --bin relay -- --help`. All command-line
options can be overridden using environment variables. Those variables are
listed in the `--help` output at the bottom of each command.

### Ports

The relay listens on port `3478`. This is the standard port for STUN/TURN and
not configurable. Additionally, the relay needs to have access to the port range
`49152` - `65535` for the allocations.

### Portal Connection

When given a `portal_token`, the relay will connect to the Firezone portal
(default `wss://api.firezone.dev`) and wait for an `init` message before
commencing relay operations.

## Design

The relay is designed in a sans-IO fashion, meaning the core components do not
cause side effects but operate as pure, synchronous state machines. They take in
data and emit commands: wake me at this point in time, send these bytes to this
peer, etc.

This allows us to very easily unit-test all kinds of scenarios because all
inputs are simple values.

The main server runs in a single task and spawns one additional task for each
allocation. Incoming data that needs to be relayed is forwarded to the main task
where it gets authenticated and relayed on success.
