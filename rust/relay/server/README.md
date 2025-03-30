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

The Firezone Relay supports Linux only. To run the Relay binary on your Linux
host:

1. Generate a new Relay token from the "Relays" section of the admin portal and
   save it in your secrets manager.
1. Ensure the `FIREZONE_TOKEN=<relay_token>` environment variable is set
   securely in your Relay's shell environment. The Relay expects this variable
   at startup.
1. Now, you can start the Firezone Relay with:

```
firezone-relay
```

To view more advanced configuration options pass the `--help` flag:

```
firezone-relay --help
```

### Ports

By default, the relay listens on port `udp/3478`. This is the standard port for
STUN/TURN. Additionally, the relay needs to have access to the port range
`49152` - `65535` for the allocations.

### Portal Connection

When given a `token`, the relay will connect to the Firezone portal and wait for
an `init` message before commencing relay operations.

### Metrics

The relay parses the `OTLP_GRPC_ENDPOINT` env variable.
Traces and metrics will be sent to an OTLP collector listening on that endpoint.

It is recommended to set additional environment variables to scope your metrics:

- `OTEL_SERVICE_NAME`: Translates to the `service.name`.
- `OTEL_RESOURCE_ATTRIBUTES`: Additional, comma-separated key=value attributes.

By default, we set the following OTEL attributes:

- `service.name=relay`
- `service.namespace=firezone`

The [`docker-init-relay.sh`](../docker-init-relay.sh) script integrates with GCE.
When `OTEL_METADATA_DISCOVERY_METHOD=gce_metadata`, the `service.instance.id`
variables is set to the instance ID of the VM.

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
