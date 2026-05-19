---
name: firezone-mise-install
description: Install a missing development tool the Firezone way - via `mise`, using the version declared in `mise.toml`, rather than reaching for `apt`, `brew`, `cargo install`, or `pipx`. Use whenever a build, lint, or test command fails with "command not found" or a version mismatch.
---

# Installing Firezone tools

Source of truth: `CLAUDE.md` -> "If a required tool is missing, check whether `mise.toml` declares it and install it via `mise` rather than through another package manager."

## Where tools are declared

The repo uses a `mise` monorepo layout (see `mise.toml` -> `[monorepo]`). Each language area has its own config root:

- `/mise.toml` - top-level tasks (lint, format) and shared settings.
- `/rust/mise.toml` - Rust toolchain plus `bpf-linker`, `cargo-deb`, `cargo-llvm-cov`, nightly version.
- `/elixir/mise.toml` - Erlang / Elixir versions.
- `/kotlin/android/mise.toml`, `/swift/apple/mise.toml` - mobile toolchains.

Always check the config root closest to the directory you are working in first, then the repo root.

## Flow when a command is missing

1. `grep -R "<tool-name>" $(find . -maxdepth 3 -name mise.toml)` - check whether mise already declares it.
2. If declared: `mise install` (from the relevant config root) and retry.
3. If not declared but needed: add it to the appropriate `mise.toml` under `[tools]` with a pinned version, then `mise install`. Do **not** install globally with another package manager and skip `mise.toml` - that breaks reproducibility for other contributors and CI.
4. Do not bypass `settings.minimum_release_age = "7d"` in the root `mise.toml` - that cooldown is a supply-chain mitigation, not a quirk.

## What `mise` provides

Beyond language toolchains, `mise` also installs the `cargo:`, `github:`, `pipx:` plugins seen in `rust/mise.toml`. Prefer those over the ambient system equivalents so versions match CI.
