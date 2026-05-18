---
name: firezone-static-analysis
description: Run Firezone's pre-commit static analysis locally before committing. Use whenever the user is about to commit, before opening a PR, or when CI's static-analysis job fails and you need to reproduce it locally. Runs the same `pre-commit` config that CI runs, via the `mise` tasks declared in the repo root `mise.toml`.
---

# Firezone static analysis

Source of truth: `mise.toml` (repo root) and `CLAUDE.md` -> "Run static analysis locally before committing."

## Tasks

All tasks are declared in the repo-root `mise.toml`:

- `mise run lint-staged` - run pre-commit hooks on staged files only. Use this in the normal pre-commit workflow.
- `mise run lint` - run pre-commit hooks on **all** files. Use this when investigating CI failures or after a large refactor.
- `mise run lint-setup` - install the lint toolchain (Python `pip` deps for pre-commit hooks, pnpm deps under `.github/` and `website/`). Run this once per fresh checkout, or after Dependabot bumps any pinned lint tool.
- `mise run format` - run `prettier --write` over `website/`. Use only when website files were touched.

## Recommended flow

```bash
# First time on a fresh checkout
mise run lint-setup

# Before every commit
git add <paths>
mise run lint-staged
```

If `lint-staged` reports auto-fixed files, `git add` them again and re-run before committing.

## When the tool itself is missing

If `mise` or `pre-commit` is not installed, see the `firezone-mise-install` skill - do not reach for `apt`, `brew`, or `pipx` first.
