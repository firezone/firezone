# AI agent rules for Firezone

## Summary

Firezone is a zero-trust access platform built on top of WireGuard.
The data plane components are built in Rust and reside in `rust/`.
The control plane components are built in Elixir and reside in `elixir/`.

## Data plane architecture

At the core of the data plane resides a shared library called [`connlib`](../rust/libs/connlib).
It combines ICE (using the `is` library) and WireGuard (using the `boringtun` library) to establish on-the-fly tunnels between Clients and Gateways.
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
For example, for Rust code, check `rust/AGENT.md`; for Elixir code, check `elixir/AGENT.md`, etc.

## Code review guidelines

- Assume that code compiles and is syntactically correct.
- Focus on consistency and correctness.
- Give extra special attention to any security-sensitive code, such as cryptographic operations, authentication logic, and access control mechanisms.

## Code contributions

- Use [Conventional Commits](https://www.conventionalcommits.org/) for PR titles. The static analysis workflow enforces a maximum length of 64 characters (see `.github/workflows/_static-analysis.yml`).
- Keep PR descriptions minimal.
  - Concise prose explaining what is changing **at a high level** and why.
  - Do not describe the code changes that can be seen in the diff again in prose.
  - Do not add a test plan section.
  - Do not include links to the Claude session.
  - Link relevant PRs / issues using `Related: #XXXX`
  - Take inspiration from https://cbea.ms/git-commit; the squash-merged PRs will have the PR description as a commit message on main.
    However, do not add hard line-breaks to the PR description itself.
    GitHub will take care of that when merging.
- Run static analysis locally before committing.
- If a required tool is missing, check whether `mise.toml` declares it and install it via `mise` rather than through another package manager.
