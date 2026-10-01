# Firezone shell scripts

This directory contains various shell scripts used for development, testing, and
deployment of the Firezone product.

## Developer Setup

We lint shell scripts in CI. To get your PR to pass, you'll want to ensure your
local development environment is set up to lint shell scripts:

1. Install [`shfmt`](https://github.com/mvdan/sh):
   - `brew install shfmt` on macOS
   - Install shfmt from https://github.com/mvdan/sh/releases for other platforms
1. Install [`shellcheck`](https://github.com/koalaman/shellcheck/tree/master):
   - `brew install shellcheck` on macOS
   - `sudo apt-get install shellcheck` on Ubuntu

Then just lint and format your shell scripts before you commit:

```
shfmt -i 4 **/*.sh
shellcheck --severity=warning **/*.sh
```

You can achieve this more easily by using `pre-commit`. See
[CONTRIBUTING](../docs/CONTRIBUTING.md#pre-commit).

### Editor setup

- [Vim](https://github.com/dense-analysis/ale/blob/master/autoload/ale/fixers/shfmt.vim)
  ([here's an example](https://github.com/jamilbk/nvim/blob/master/init.vim#L159)
  using ALE)
- [VSCode](https://marketplace.visualstudio.com/items?itemName=mkhl.shfmt)

## Elixir dead code

Run `mise run //:elixir:dead-code --check` to compare public function names
against `elixir/dead-code-exceptions.json`. Run `mise run //:elixir:dead-code`
to update the exceptions after reviewing the diff, then commit the JSON file.
CI rejects both new violations and exceptions that are no longer needed.

This is a basic name-only scan of tracked working-tree files: definitions come
from Elixir `.ex`/`.exs` files, and references can be in any tracked text file.
It does not resolve modules or arities. Comments, strings, and documentation
count as references, and a `def` in a documentation example can be reported.
Callbacks and functions invoked dynamically may need exceptions. Stage new
files before running the task so Git includes them in the scan.

## Scripting tips

- Use `#!/usr/bin/env bash` along with `set -euox pipefail` in general for dev
  and test scripts.
- In Docker images and other minimal envs, stick to `#!/bin/sh` and simply
  `set -eu`.
