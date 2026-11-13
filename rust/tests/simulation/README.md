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

`run_relay` simulates a relay client, a relay and the portal that hands the client the relay and its credentials, with the client checked against a reference model.
