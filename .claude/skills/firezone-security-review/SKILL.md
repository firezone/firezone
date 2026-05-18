---
name: firezone-security-review
description: Perform a focused security review on Firezone changes touching cryptography, authentication, or access control. Use when a diff modifies `rust/libs/connlib/snownet`, WireGuard / boringtun integration, key material, ICE credentials, the Elixir portal's auth modules, RBAC / policy code, or anything that decides who is allowed to reach what. The general code-review guidelines say to give this code "extra special attention" - this skill says how.
---

# Firezone security review

Source of truth: `CLAUDE.md` -> "Code review guidelines" and `docs/AGENT.md`.

## Scope

Code worth flagging for extra scrutiny:

- `rust/libs/connlib/snownet` - ICE, STUN, key exchange.
- `rust/libs/connlib/tunnel` and `rust/libs/connlib/*` touching boringtun / WireGuard state.
- Anything handling private keys, pre-shared keys, session keys, certificates, or ICE credentials.
- `elixir/lib/portal*` modules that perform authentication, authorization, or policy evaluation.
- Token issuance, validation, refresh, and revocation paths in either plane.
- Code paths that decide whether a packet is forwarded, dropped, or routed to a specific peer.

## Review checklist

### Crypto

- Are nonces / IVs unique per key? Counter resets after rekey?
- Are secret comparisons constant-time (`subtle::ConstantTimeEq`, `crypto::Eq`, etc.)?
- Is key material ever logged, `Debug`-printed, or serialized into errors? It must not be. (See also `firezone-log-audit`.)
- Is key material zeroized on drop where reasonable (`zeroize::Zeroize`)?
- Does any code roll its own primitive instead of using `ring`, `rustcrypto`, or `boringtun`?

### Authentication

- Is every entry point reachable without a token actually intended to be public?
- Are token expiry, audience, issuer, and signature all validated - not just signature?
- Do error paths leak whether a user exists, a token was malformed, or it was just expired?
- Are auth decisions cached? If so, how long, and what invalidates the cache?

### Authorization / access control

- Are policy decisions evaluated **server-side**, not implied by the client request?
- Are resource IDs from the request authorized for the **caller**, not just well-formed?
- Are list endpoints filtered by tenant / account before the response is built, not after?
- Is there a missing check on the `update` / `delete` path that exists on `read`?

### Operational

- Does a new failure mode produce a flood of `error!` logs (denial-of-service-by-logging)?
- Does a panic exist on attacker-influenced input?
- Does an unbounded queue or map exist on attacker-influenced input?

## Output

When reporting, separate **must fix before merge** from **worth a follow-up**. Cite file and line. For each finding, state the threat (who can do what) before the remediation.
