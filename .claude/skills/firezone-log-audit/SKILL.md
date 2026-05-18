---
name: firezone-log-audit
description: Audit `tracing` log statements in Firezone Rust code against the project's log-level and sensitive-data policy. Use when adding or reviewing any `tracing::trace!`, `debug!`, `info!`, `warn!`, `error!`, or `Span` in `rust/`, or when a log line might contain a domain name, IP address, or other customer data. This skill catches mistakes the compiler cannot.
---

# Firezone log audit

Source of truth: `rust/AGENT.md` -> "Use of log levels".

## Sensitive data

- **Domain names, customer IP addresses, and similar identifiers MUST NOT be logged above `DEBUG`.** When in doubt, drop to `DEBUG` or omit the field.
- Anything triggered by an individual network packet **MUST** be at `TRACE`, not `DEBUG`.

These two rules are non-negotiable. They are the first thing to grep for in a review.

## Level guide

| Level   | When to use                                                                                                                                                       |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TRACE` | Code that follows along with execution unconditionally - every incoming packet, every channel send.                                                               |
| `DEBUG` | A condition or minor state change. "I would want to know this triggered to understand what the system did." Early exits and deviations from the happy path.       |
| `INFO`  | Significant, often user-impacting state changes - connection established / closed, configuration applied.                                                         |
| `WARN`  | Unusual but recoverable. An ops person may alert on a _rate_ of these. Ask: "would I want to be paged at 3am for this?" If no, it stays `WARN`; if yes, escalate. |
| `ERROR` | Things are broken and we cannot continue this operation. Rare.                                                                                                    |

## Spans

- Prefer `tracing::Span` to attach context (`connection_id`, `resource_id`, ...) over repeating fields in every event - especially in highly concurrent code where events interleave.
- Use **identifiers**, not whole structs. `?conn_id` is good; `?connection` that debug-prints the entire connection struct is not.

## Structured fields vs format strings

Always prefer structured fields:

```rust
tracing::info!(?duration_since_intent, "Established new connection");
```

over interpolation:

```rust
tracing::info!("Established new connection in {duration_since_intent:?}");
```

Structured fields are searchable, filterable, and survive JSON formatting; the message is a constant string suitable for grouping.

## Review checklist

When reviewing a diff that touches logging:

1. Any `info!` / `warn!` / `error!` carrying a domain or IP? -> downgrade or strip the field.
2. Any log inside a per-packet hot path? -> must be `TRACE`.
3. Any whole-struct `?value` in a span or event? -> replace with an ID.
4. Any `format!`-style interpolation that could be a field? -> convert to a field.
5. Any `warn!` that fires on normal operation? -> downgrade to `debug!` or remove.
