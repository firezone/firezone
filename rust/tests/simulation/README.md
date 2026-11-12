# Simulation testing

A deterministic, in-process simulation of clients, gateways, relays and the portal.
The tunnel state machines run against a simulated network and are checked against a reference model after every transition.

An input is a sequence of bytes that decides the topology and the transitions applied to it.
With the same RNG seeds and clock anchor, the same input always produces the same run.

A fuzzer is one way of driving the simulation: the `tunnel` target of the [fuzzing harness](../fuzz/README.md) feeds it inputs, and its corpus serves as the regression suite.
Built with the `ijon` feature for AFL++ discovery, the simulation records [IJON feedback](https://github.com/AFLplusplus/AFLplusplus/blob/stable/docs/IJON.md) for meaningful observed states.
