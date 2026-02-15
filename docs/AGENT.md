# AI agent rules for Firezone

## Summary

Firezone is a zero-trust access platform built on top of WireGuard.
The data plane components are built in Rust and reside in `rust/`.
The control plane components are built in Elixir and reside in `elixir/`.

## Data plane architecture

At the core of the data plane resides a shared library called [`connlib`](../rust/libs/connlib).
It combines ICE (using the `str0m` library) and WireGuard (using the `boringtun` library) to establish on-the-fly tunnels between Clients and Gateways.
The entry-point for the data plane is [`Tunnel`](../rust/libs/connlib/tunnel) which acts as a big event-loop combining three components:

- A platform-specific TUN device
- A sans-IO state component representing either the Client or the Gateway
- A platform-specific UDP socket

Packets from IO sources (TUN device and UDP socket) are passed to the state component, resulting in a UDP or IP packet.
The state component also manages ICE through the [`snownet`](../rust/libs/connlib/snownet) library, so some UDP traffic is handled internally and does not yield an IP packet.

These three components are split into multiple threads and connected via bounded channels:

- 1 thread for reading from the TUN device
- 1 thread for writing to the TUN device
- 1 thread for handling IPv4 UDP traffic with 1 task each for sending / receiving
- 1 thread for handling IPv6 UDP traffic with 1 task each for sending / receiving
- 1 task on the "main" thread that holds the state and reads / writes from and to the channels connecting to the IO threads

## Coding guidelines

For guidelines on generating or reviewing specific parts of the codebase, check for an `AGENT.md` file in the corresponding sub-directory.
For example, for Rust code, checking `rust/AGENT.md`, for Elixir code, check `elixir/AGENT.md`, etc.

## Code review guidelines

- Assume that code compiles and is syntactically correct.
- Focus on consistency and correctness.
