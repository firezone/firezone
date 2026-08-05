# Shared helpers for the Firezone package derivations.
{
  crane,
  lib,
  pkgs,
}:
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

  craneLib = (crane.mkLib pkgs).overrideToolchain toolchain;

  # Only the Rust workspace; changes elsewhere in the monorepo don't rebuild.
  # Flake sources contain only git-tracked files, so build artifacts like
  # gui-client/dist and target/ are already excluded.
  src = ../../rust;

  # `cargo update --workspace` runs on every release, so any fixed-output
  # vendor hash would need bumping each time. crane resolves the git
  # dependencies with `builtins.fetchGit` at the revs pinned in Cargo.lock,
  # which keeps the Rust dependency set hash-free.
  craneVendorDir = craneLib.vendorCargoDeps { cargoLock = ../../rust/Cargo.lock; };

  # The same vendored sources, re-exported under the layout `cargoSetupHook`
  # expects: it reads the source replacement config from `.cargo/` below the
  # vendor directory, crane writes it to the top level. crane's config names
  # the crate directories by absolute store path, so the symlink is enough to
  # point both builds at the very same sources.
  #
  # They have to agree: cargo compares the mtime of every source file against
  # the artifacts inherited from `cargoArtifacts`, and passing `cargoDeps`
  # instead would copy the vendor directory into the build tree, dating every
  # source after every rlib and recompiling the lot.
  vendorDir = pkgs.runCommandLocal "firezone-cargo-vendor-dir" { } ''
    mkdir -p $out/.cargo
    ln -s ${craneVendorDir}/config.toml $out/.cargo/config.toml
  '';

  # `system_certs` switches phoenix-channel to the platform TLS verifier
  # (NixOS provides roots via security.pki). Frame pointers match the
  # official release builds (rust/.cargo/config.toml, which the derivations
  # delete because its per-target rustflags conflict with buildRustPackage).
  rustflags = "--cfg system_certs -C force-frame-pointers=yes";

  # Everything cargo folds into a unit's fingerprint has to match between the
  # dependency-only build below and the package build, or nothing is reused.
  cargoEnv = {
    RUSTFLAGS = rustflags;

    # `cargoBuildHook` always passes `--target`; matching it keeps the target
    # directory layout the same on both sides.
    CARGO_BUILD_TARGET = pkgs.stdenv.hostPlatform.rust.rustcTarget;

    # `cargoBuildHook` sets this so stdenv handles stripping instead of cargo.
    # `strip` is part of the profile, and the profile is part of every unit's
    # fingerprint.
    CARGO_PROFILE_RELEASE_STRIP = "false";
  };

  # Dependency-only build of one workspace member.
  #
  # `buildRustPackage` compiles the whole dependency graph inside the package
  # derivation, whose hash covers all of rust/, so any source change recompiles
  # ~900 crates from scratch and the binary cache never helps. crane builds the
  # same graph against a stubbed-out copy of the workspace instead: the result
  # depends only on Cargo.lock, the manifests, the toolchain and the flags
  # above, so it survives ordinary source changes and is substituted from the
  # cache.
  #
  # Scoped per member rather than once for the whole workspace: the resolver
  # unifies features across all members of a `--workspace` build, and artifacts
  # compiled under a different feature set get recompiled anyway.
  cargoArtifactsFor =
    {
      crate,
      features ? [ ],
      ...
    }@args:
    craneLib.buildDepsOnly (
      {
        inherit src;

        cargoVendorDir = craneVendorDir;

        pname = crate;
        # Deliberately fixed: `versions` below moves on every release, and
        # naming these after it would miss the cache each time.
        version = "0";

        cargoExtraArgs =
          "--locked -p ${crate}"
          + lib.optionalString (features != [ ]) " --features ${lib.concatStringsSep "," features}";

        env = cargoEnv;

        postPatch = "rm -f .cargo/config.toml";
      }
      // builtins.removeAttrs args [
        "crate"
        "features"
      ]
    );

  # `buildRustPackage`, wired up to reuse the artifacts above.
  buildRustPackage =
    args:
    rustPlatform.buildRustPackage (
      args
      // {
        inherit src;

        # Relative to the source root, where postUnpack links it into place.
        cargoVendorDir = "vendor";

        postUnpack = ''
          ln -s ${vendorDir} "$sourceRoot/vendor"
        ''
        + (args.postUnpack or "");

        nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
          craneLib.inheritCargoArtifactsHook
          pkgs.rsync
          pkgs.zstd
        ];

        env = cargoEnv // (args.env or { });
      }
    );

  # Current released version of each component we package. Read from the
  # sentinel comments here (kept in sync by scripts/bump-versions.sh) rather
  # than from Cargo.toml, whose `version` tracks the next, in-development
  # release.
  versions = {
    # mark:current-gateway-version
    gateway = "1.5.2";

    # mark:current-headless-version
    headless = "1.5.10";

    # mark:current-gui-version
    gui = "1.5.15";
  };

  meta = {
    homepage = "https://www.firezone.dev";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
