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
[CONTRIBUTING](../CONTRIBUTING.md#pre-commit).

### Editor setup

- [Vim](https://github.com/dense-analysis/ale/blob/master/autoload/ale/fixers/shfmt.vim)
  ([here's an example](https://github.com/jamilbk/nvim/blob/master/init.vim#L159)
  using ALE)
- [VSCode](https://marketplace.visualstudio.com/items?itemName=mkhl.shfmt)

## Scripting tips

- Use `#!/usr/bin/env bash` along with `set -euo pipefail` in general for dev
  and test scripts.
- In Docker images and other minimal envs, stick to `#!/bin/sh` and simply
  `set -eu`.
