---
name: firezone-pr
description: Draft a Firezone PR title and description that follow the repo's contribution rules. Use when opening, retitling, or rewriting a pull request in this repo - the title must follow Conventional Commits and stay under 64 characters (enforced by `.github/workflows/_static-analysis.yml`), and the description must be minimal high-level prose with no test plan or Claude session link.
---

# Firezone PR drafting

Source of truth: `CLAUDE.md` -> "Code contributions" and `docs/AGENT.md`.

## Title

- Conventional Commits: `type(scope): subject`.
- Length: 64 characters or fewer. CI fails otherwise (`_static-analysis.yml`).
- Common types in this repo: `feat`, `fix`, `chore`, `ci`, `build`, `docs`, `refactor`, `test`.
- Common scopes: `rust`, `portal`, `gateway`, `relay`, `gui-client`, `headless-client`, `android`, `apple`, `website`, `connlib`, `snownet`, `claude`, `deps`.
- The squash-merge commit message on `main` will be the PR title, so write it for that audience.

Check the length before submitting:

```bash
printf '%s' "feat(scope): subject" | wc -c
```

## Description

- One or two short paragraphs explaining **what** is changing at a high level and **why**.
- Do not restate the diff. If a reader can see it in the patch, do not narrate it in prose.
- Do not include a "Test plan" section.
- Do not include any `https://claude.ai/code/session_...` links.
- Link related work with `Related: #1234` (one per line). Use this for both PRs and issues.
- Take inspiration from https://cbea.ms/git-commit.

## Template

```
<one or two sentences: what + why, at a high level>

Related: #XXXX
```

That is the entire template. Omit `Related:` if there is nothing to link.
