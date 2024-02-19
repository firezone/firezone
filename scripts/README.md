# Firezone shell scripts

This directory contains various shell scripts used for development, testing, and
deployment of the Firezone product.

## Developer Setup

We lint shell scripts in CI. To get your PR to pass, you'll want to ensure your
local development environment is set up to lint shell scripts:

1. Ensure [`shfmt`](https://github.com/mvdan/sh) is installed on your system and
   available in your `PATH`. You'll want to configure it to use spaces instead
   of tabs with the `-i 4` argument. Consult the appropriate editor plugin
   documentation for how to do this:
   - [Vim](https://github.com/dense-analysis/ale/blob/master/autoload/ale/fixers/shfmt.vim)
     ([here's an example](https://github.com/jamilbk/nvim/blob/master/init.vim#L159)
     using ALE)
   - [VSCode](https://marketplace.visualstudio.com/items?itemName=mkhl.shfmt)
1. Ensure [`shellcheck`](https://github.com/koalaman/shellcheck/tree/master) is
   installed on your system and available in your `PATH`. You'll want to
   configure it to use the `shellcheck` binary in your `PATH` in your editor
   plugin settings.
