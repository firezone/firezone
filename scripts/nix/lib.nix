# Shared helpers for the Firezone package derivations.
{ lib, pkgs }:
rec {
  # Pin the Rust toolchain to the same channel the rest of the repo uses.
  # Bumping rust-toolchain.toml therefore needs no Nix changes (at most a
  # `nix flake update rust-overlay` if the release is very recent).
  toolchainChannel = (lib.importTOML ../../rust/rust-toolchain.toml).toolchain.channel;

  toolchain = pkgs.rust-bin.stable.${toolchainChannel}.minimal;

  rustPlatform = pkgs.makeRustPlatform {
    cargo = toolchain;
    rustc = toolchain;
  };

  # Only the Rust workspace; changes elsewhere in the monorepo don't rebuild.
  # Flake sources contain only git-tracked files, so build artifacts like
  # gui-client/dist and target/ are already excluded.
  src = ../../rust;

  # `cargo update --workspace` runs on every release, so any fixed-output
  # vendor hash would need bumping each time. Importing the lockfile with
  # builtin git fetching keeps the Rust dependency set hash-free: revs are
  # pinned by Cargo.lock and fetched at evaluation time.
  cargoLock = {
    lockFile = ../../rust/Cargo.lock;
    allowBuiltinFetchGit = true;
  };

  # `system_certs` switches phoenix-channel to the platform TLS verifier
  # (NixOS provides roots via security.pki). Frame pointers match the
  # official release builds (rust/.cargo/config.toml, which the derivations
  # delete because its per-target rustflags conflict with buildRustPackage).
  rustflags = "--cfg system_certs -C force-frame-pointers=yes";

  crateVersion = crateDir: (lib.importTOML (src + "/${crateDir}/Cargo.toml")).package.version;

  meta = {
    homepage = "https://www.firezone.dev";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
