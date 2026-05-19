# AI agent rules for Firezone

## Summary

Firezone is a zero-trust access platform built on top of WireGuard.
The data plane components are built in Rust and reside in `rust/`.
The control plane components are built in Elixir and reside in `elixir/`.

## Coding guidelines

For guidelines on generating or reviewing specific parts of the codebase, check for an `AGENT.md` file in the corresponding sub-directory.
For example, for Rust code, check `rust/AGENT.md`; for Elixir code, check `elixir/AGENT.md`, etc.

Task-specific rules (data-plane architecture, log-level policy, PR conventions, `mise` tooling, security review, MCP impersonation guardrail, etc.) are encoded as invokable skills under `.claude/skills/` and surfaced on demand rather than kept always-loaded here.

## Code review guidelines

- Assume that code compiles and is syntactically correct.
- Focus on consistency and correctness.
