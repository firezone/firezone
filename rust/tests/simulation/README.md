# Simulation testing

Deterministic, in-process simulations of connlib's components.
Each simulation runs the real state machines against simulated peers on a simulated network and checks them after every transition.

An input is a sequence of bytes that decides the setup and the transitions applied to it.
With the same RNG seeds and clock anchor, the same input always produces the same run.

A fuzzer is one way of driving a simulation: a target of the [fuzzing harness](../fuzz/README.md) feeds it inputs, and its corpus serves as the regression suite.

## `tunnel`

`run_tunnel` simulates clients, gateways, relays and the portal, with the tunnel state machines checked against a reference model.
Built with the `ijon` feature for AFL++ discovery, it records [IJON feedback](https://github.com/AFLplusplus/AFLplusplus/blob/stable/docs/IJON.md) for meaningful observed states.

## `relay`

`run_relay` simulates a relay client, a relay and the portal that hands the client the relay and its credentials.
A transition is something that happens to them: time passes, credentials are rotated or expire, the client roams, the relay reboots, the network or the portal is gone for a while, or a datagram arrives that neither side sent.
Each transition runs until the client and the relay have settled.

The reference model then answers two questions.
Must relaying work? It must, unless the client can neither use its credentials nor get new ones, or cannot reach the relay; a probe checks that by sending data between a peer and the client through every relay address the client announced.
Was the transition allowed to interrupt relaying? If not, the client's relay addresses must not have changed.
