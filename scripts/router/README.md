# Router

This container acts as a simple router how they are found on the public Internet.
By default, no inbound traffic is allowed, except for:

- responses of previously outgoing connections
- explicit port forwarding

The router uses `nftables` to enforce these rules.

We also make several assumptions about the docker-compose setup that we are running in:

- The network interface between the router and its container must be called `internal`
- The public network interface on the other side must be called `internet`
- IPv4 and IPv6 must be available on both interfaces
