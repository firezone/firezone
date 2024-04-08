# Nix tooling

To use the dev-shell specified in this repository, simply run `nix develop`.

There is also an `.envrc` file at the repository root, meaning if you have `direnv` installed and hooked up for your shell, `nix develop` will be run automatically as soon as you enter the repository.

## Rust nightly

If you need a nightly version of Rust, you can open a devShell with the latest Rust nightly version installed using: `nix develop .#nightly`
