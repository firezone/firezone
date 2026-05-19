---
name: firezone-rust-style
description: Apply Firezone's Rust coding conventions when writing or reviewing code under `rust/`. Use when generating new Rust code in this repo, refactoring existing Rust code, or reviewing a Rust diff for style consistency. Covers iterator-first style, turbofish, `let-else` early returns, test conventions, and module ordering.
---

# Firezone Rust style

Source of truth: `rust/AGENT.md`.

## Code style

- **No excessive comments.** Only comment the _why_ when it is non-obvious. Identifiers and signatures cover the _what_.
- **Functional over imperative.** Prefer iterator chains (`map`, `filter`, `collect`, `try_fold`, ...) over `for` loops that push into a `Vec`.
- **Turbofish over type hints.** Write `parse::<u32>()`, not `let x: u32 = s.parse()?;` when the turbofish is clearer at the call site.
- **Early returns; flatten the happy path.**
  - Use `let-else` instead of `if let Some(x) = ... { ... }` when the `None` branch returns.
  - Use `let Ok(x) = ... else { return ... };` over `match` for two-arm error guards.
  - Goal: the happy path stays at the leftmost indentation; failure cases are short and visible at the top.

## Tests

- Test the **public API** of the module, not the private internals. If a test needs to reach into private state, that is a hint to either expose a real API or rethink what is being tested.
- Follow **arrange / act / assert**, with a blank line between the three phases when it aids readability.

## Module layout

Order items within a module from high to low priority:

1. Public API (`pub` types and functions).
2. The functions those call, roughly in call order.
3. Lower-level helpers last.

Scrolling top to bottom should feel like drilling down through the module. A reader who only reads the first screen should understand what the module _does_.

## Logging

Logging is non-trivial in this codebase - see the `firezone-log-audit` skill for the full level / span / sensitive-data rules.
