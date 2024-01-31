# Router

This directory contains a Debian-based router implemented on top of nftables.

It expects to be run with two network interfaces:

- `eth1`: The "external" interface.
- `eth0`: The "internal" interface.

The order of these interfaces depends on lexical sorting the docker networks names.

The order of these is important.
The router cannot possibly know which one is which and thus assumes that `eth0` is the external one and `eth1` the internal one.
The firewall is set up to take incoming traffic on `eth1` and forward + masquerade it to `eth0`.

It also expects an env variable `DELAY_MS` to be set and will apply this delay as part of the routing process[^1].

[^1]: This is done via `tc qdisc` which only works for egress traffic. To ensure the delay applies in both directions, we divide it by 2 and apply it on both interfaces.
