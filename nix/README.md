# Firezone on NixOS

First-party Nix packages and NixOS modules for the Firezone Gateway, the
headless Linux client, and the GUI client. All three are built from the
source in this repository.

## Usage

Pin the release tag of the component you care about and import the module
you need:

```nix
{
  inputs.firezone.url = "github:firezone/firezone/gateway-1.5.3";
}
```

```nix
# configuration.nix
{ inputs, ... }:
{
  imports = [ inputs.firezone.nixosModules.gateway ];

  # Substitute pre-built, Firezone-signed binaries instead of compiling
  # from source. Optional but strongly recommended.
  nix.settings = {
    extra-substituters = [ "https://artifacts.firezone.dev/nix" ];
    extra-trusted-public-keys = [ "artifacts.firezone.dev/nix-1:<public key>" ];
  };

  services.firezone.gateway = {
    enable = true;
    tokenFile = "/var/lib/secrets/firezone-gateway-token";
    nat.externalInterface = "eth0";
  };
}
```

Available modules: `nixosModules.gateway`, `nixosModules.headless-client`,
`nixosModules.gui-client` (or `nixosModules.default` for all three).
Packages are also exposed via `packages.<system>.*` and `overlays.default`.

### GUI client notes

- Add desktop users to `services.firezone.gui-client.allowedUsers` so they
  may talk to the tunnel daemon. The group membership takes effect on next
  login.
- The session token is stored via the Secret Service API. The module
  enables gnome-keyring by default; set `provisionKeyring = false` on
  desktops that already provide one (e.g. KWallet).
- The tray icon uses the StatusNotifierItem protocol. GNOME requires the
  AppIndicator extension for it to show.

### Tag-pinning semantics

Releases are cut per component (`gateway-X.Y.Z`, `headless-client-X.Y.Z`,
`gui-client-X.Y.Z`) but all tags point into this monorepo. Pinning any tag
gives you all three packages at whatever versions are in-tree at that
commit; CI builds and caches all of them, but only the tagged component's
version is an official release. Pin the tag of the component you care
about.

### Binary cache

Release CI builds `x86_64-linux` and `aarch64-linux` closures, signs them
with the `artifacts.firezone.dev/nix-1` ed25519 key, and uploads them to
the cache. If the cache is unreachable Nix falls back to building from
source: slower, never broken. Note that `nix.settings` changes take effect
only after a rebuild, so the very first build with the substituter
configured may still compile from source.

## Maintenance

Design goal: **zero Nix edits per release.**

- Package versions are read from the crates' `Cargo.toml` files at
  evaluation time, so `scripts/bump-versions.sh` needs no Nix awareness.
- Rust dependencies (including git dependencies) come straight from
  `rust/Cargo.lock` via `importCargoLock` with builtin git fetching: no
  vendor hash exists, so `cargo update --workspace` on release never
  requires a Nix change. The cost: the first evaluation on a fresh machine
  fetches the git dependencies at eval time.
- The Rust toolchain follows `rust/rust-toolchain.toml`. If CI fails with
  an unknown-toolchain error right after a toolchain bump, run
  `nix flake update rust-overlay`.
- The **single maintained hash** is `pnpmDeps.hash` in
  `nix/packages/firezone-gui-client/frontend.nix`. It must be bumped
  whenever `gui-client/pnpm-lock.yaml` changes; the CI failure message
  prints the expected value — paste it and re-run.
- Frontend build steps in `frontend.nix` mirror `gui-client/build.sh` and
  the `postinstall` script in `gui-client/package.json`; keep them in sync
  when those change.
- Hardcoded FHS paths in Rust code (like the IPC peer-check path, see
  `FIREZONE_GUI_PEER_EXE` in `gui-client/src-tauri/src/ipc/unix/peer_check/linux.rs`)
  break NixOS builds silently. The Nix CI job on `rust/` PRs is what
  catches these at review time.

### Cache publishing

`scripts/upload/nix-cache.sh` signs the closures with
`NIX_CACHE_SIGNING_KEY` and syncs them to the `nix` container of the
`firezoneartifacts` Azure storage account, which is served at
`https://artifacts.firezone.dev/nix`. It runs from `.github/workflows/_nix.yml`
on main and when a release is published. NAR files are content-addressed
and shared between releases — never apply age-based lifecycle rules to the
container.

Key rotation: generate `artifacts.firezone.dev/nix-2` with
`nix key generate-secret`, sign with both keys for a transition period
(signatures accumulate), publish both public keys, then retire `-1`.
