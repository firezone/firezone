---
name: firezone-data-plane-trace
description: Explain how a packet flows through Firezone's data plane, or locate the right component for a packet-path question. Use when answering questions about `connlib`, `Tunnel`, ICE, WireGuard integration, TUN device handling, or the thread / channel topology in `rust/libs/connlib/`. Also useful for onboarding answers and grounding architectural review comments.
---

# Firezone data plane: packet flow

Source of truth: `CLAUDE.md` and `docs/AGENT.md` -> "Data plane architecture".

## The three components

The data-plane entry point is [`Tunnel`](../../../rust/libs/connlib/tunnel). It is a single big event loop that mediates between three components:

1. A **platform-specific TUN device** - the OS interface that delivers IP packets from / to the host.
2. A **sans-IO state component** - either the Client or the Gateway state machine. Pure logic, no I/O.
3. A **platform-specific UDP socket** - the wire to the peer.

Packets from either I/O source (TUN, UDP) feed into the state. The state produces UDP or IP packets in return. Some UDP traffic is consumed internally by ICE - that traffic is handed to [`snownet`](../../../rust/libs/connlib/snownet) inside the state and never yields a payload IP packet.

```
   TUN read  ->\                 /-> TUN write
                >  state (sans-IO, Client or Gateway)
   UDP read  ->/                 \-> UDP write
                         |
                         v
                      snownet (ICE, internal-only UDP)
```

## Thread / task layout

Three sources, one brain. Connected by bounded channels:

- 1 thread reading the TUN device.
- 1 thread writing the TUN device.
- 1 thread for IPv4 UDP, with one task each for send and receive.
- 1 thread for IPv6 UDP, with one task each for send and receive.
- 1 task on the **main** thread owning the state, draining inbound channels and feeding the outbound channels.

The state is single-threaded - it does not need internal locking. Everything crossing a thread boundary crosses a bounded channel. Backpressure is therefore explicit at the channel.

## Using this in review

When reviewing a packet-path change, ask:

1. Which of the three components is changing?
2. Does the change cross a channel boundary? If so, is the channel still bounded and does it backpressure correctly?
3. Is per-packet code on `TRACE` only? (See `firezone-log-audit`.)
4. Does state-component code touch I/O directly? It should not - it is sans-IO.
