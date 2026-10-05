# Firezone on NixOS

First-party Nix packages and NixOS modules for the Firezone Gateway, the headless Linux client, and the GUI client.
All three are built from the source in this repository.

## Usage

Pin the release tag of the component you care about and import the module you need:

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
    extra-trusted-public-keys = [ "artifacts.firezone.dev/nix-1:T4LHdL1HeA6LE9qgu0Po0j3RIlelKZz8pzqnzEAIRfI=" ];
  };

  services.firezone.gateway = {
    enable = true;
    tokenFile = "/var/lib/secrets/firezone-gateway-token";
    nat.externalInterface = "eth0";
  };
}
```

Available modules: `nixosModules.gateway`, `nixosModules.headless-client`, `nixosModules.gui-client` (or `nixosModules.default` for all three).
Packages are also exposed via `packages.<system>.*` and `overlays.default`.

### Running multiple components at different versions

Each tag pins the whole monorepo, so to track different components at different release versions, add one input per component and import each module from its own input:

```nix
{
  inputs.firezone-gateway.url = "github:firezone/firezone/gateway-1.5.3";
  inputs.firezone-gui.url = "github:firezone/firezone/gui-client-1.5.1";
}
```

```nix
# configuration.nix
{ inputs, ... }:
{
  imports = [
    inputs.firezone-gateway.nixosModules.gateway
    inputs.firezone-gui.nixosModules.gui-client
  ];
}
```

The `gateway` module then builds from the `gateway-1.5.3` checkout and the `gui-client` module from the `gui-client-1.5.1` checkout.

### GUI client notes

- `services.firezone.gui-client.allowedUsers` is required: list the desktop users that may talk to the tunnel daemon.
  The group membership takes effect on next login.
- The session token is stored via the Secret Service API.
  The module enables gnome-keyring by default; desktops that ship their own provider (e.g. KWallet) can override with `services.gnome.gnome-keyring.enable = lib.mkForce false`.
- The tray icon uses the StatusNotifierItem protocol.
  GNOME requires the AppIndicator extension for it to show.

### Tag-pinning semantics

Releases are cut per component (`gateway-X.Y.Z`, `headless-client-X.Y.Z`, `gui-client-X.Y.Z`) but all tags point into this monorepo.
Pinning any tag gives you all three packages at whatever versions are in-tree at that commit; CI builds and caches all of them, but only the tagged component's version is an official release.
Pin the tag of the component you care about.

### Binary cache

Release CI builds `x86_64-linux` and `aarch64-linux` closures, signs them with the `artifacts.firezone.dev/nix-1` ed25519 key, and uploads them to the cache.
If the cache is unreachable Nix falls back to building from source: slower, never broken.
Note that `nix.settings` changes take effect only after a rebuild, so the very first build with the substituter configured may still compile from source.

## Maintenance

Design goal: **zero Nix edits per release.**

- Package versions come from their crates’ `Cargo.toml` files, matching the versions being built, including release drafts.
- Rust dependencies (including git dependencies) come straight from `rust/Cargo.lock` via crane with builtin git fetching: no vendor hash exists, so `cargo update --workspace` on release never requires a Nix change.
  The cost: the first evaluation on a fresh machine fetches the git dependencies at eval time.
- The Rust toolchain follows `rust/rust-toolchain.toml`.
  If CI fails with an unknown-toolchain error right after a toolchain bump, run `nix flake update rust-overlay`.
- The **single maintained hash** is `pnpmDeps.hash` in `scripts/nix/packages/firezone-gui-client/frontend.nix`.
  Refresh it on Linux with `scripts/nix/update-pnpm-hash.sh` whenever `gui-client/pnpm-lock.yaml` changes.
  Nix CI and GUI release drafting run `scripts/nix/update-pnpm-hash.sh --check`, which forces a fresh dependency fetch and fails on a stale pin or fetch error.
  The release draft and artifact builds depend on this check; commit the corrected hash before retrying. CI never silently repairs the release checkout.
- Frontend build steps in `frontend.nix` mirror `gui-client/build.sh` and the `postinstall` script in `gui-client/package.json`; keep them in sync when those change.
- Hardcoded FHS paths in Rust code (like the IPC peer-check path, see `FIREZONE_GUI_PEER_EXE` in `gui-client/src-tauri/src/ipc/unix/peer_check/linux.rs`) break NixOS builds silently.
  The Nix CI job on `rust/` PRs is what catches these at review time.

### Cache publishing

`scripts/upload/nix-cache.sh` signs the closures with `NIX_CACHE_SIGNING_KEY` and syncs them to the `nix` container of the `firezoneartifacts` Azure storage account, which is served at `https://artifacts.firezone.dev/nix`.
It runs from `.github/workflows/_nix.yml` on main and when a release is published.
NAR files are content-addressed and shared between releases; never apply age-based lifecycle rules to the container.

Key rotation: generate `artifacts.firezone.dev/nix-2` with `nix key generate-secret`, sign with both keys for a transition period (signatures accumulate), publish both public keys, then retire `-1`.

### Dependabot hash updates

After the strict hash-validation change in [PR #15573](https://github.com/firezone/firezone/pull/15573) is merged, the `Compute Dependabot pnpm hash` workflow fetches dependencies on GUI npm Dependabot PRs with read-only repository permissions, no write credentials, and no OIDC access.
The separate `Commit Dependabot pnpm hash` workflow runs trusted default-branch code and consumes only a bounded JSON artifact from that run.
It checks the source workflow, repository, Dependabot PR owner, base/head branches, exact head commit, and changed files before obtaining a write token.
Only modifications to `rust/gui-client/package.json`, `rust/gui-client/pnpm-lock.yaml`, and the frontend hash pin are eligible; mixed updates outside that list must be refreshed manually.
The writer reads PR contents through GitHub's API, rejects frontend changes outside the pin, and creates a commit changing only that pin with the original PR head as its sole parent.
It never executes PR code, force-pushes, approves, or merges the PR, and it revokes the installation token after use.
Its commit message includes `[dependabot skip]` so Dependabot can discard the generated hash commit when rebasing; the automation then recomputes the hash for the new head.
Strict CI validation still verifies the resulting commit; the computed hash is untrusted data, not dependency approval.

One-time setup by a repository/organization administrator:

1. Merge PR #15573 before this automation PR, so the dependency-only updater and strict validation are available on `main`.
2. Create a dedicated GitHub App owned by `firezone`, with **Repository permissions → Contents: Read and write** and **Metadata: Read-only** (automatic).
   Disable webhooks; no webhook events, organization permissions, or ruleset bypass are needed.
   Install the App on **only `firezone/firezone`**.
3. In repository **Settings → Secrets and variables → Actions → Variables**, add `NIX_HASH_APP_ID` with the App ID.
4. Generate a private key for the App and add its complete PEM contents as the repository **Actions secret** `NIX_HASH_APP_PRIVATE_KEY`.
   Do not add this key to Dependabot secrets: the computation workflow does not need it.
5. Merge this automation PR, then ask Dependabot to rebase an open GUI npm PR (or wait for its next update).
   Both workflows must be on the default branch before automatic commits can run.
6. Verify that the writer commits only the frontend hash and that normal PR CI runs on that new commit before merging the dependency update.

The writer is disabled while `NIX_HASH_APP_ID` is unset; remove that variable to pause automatic commits.
The App token is short-lived and restricted to Contents write on this repository, and App-authenticated pushes trigger normal CI.
The App's bot commit needs no bypass of the protected default branch: it updates the Dependabot branch and goes through normal review/merge requirements.
