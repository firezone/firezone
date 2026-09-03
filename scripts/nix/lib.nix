# Shared helpers for the Firezone package derivations.
{
  crane,
  lib,
  pkgs,
  rev,
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

  # The commit the flake was evaluated from, or null when unknown.
  inherit rev;

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

  # `cargoBuildHook` always passes `--target`, and sets `strip` so that stdenv
  # does the stripping instead of cargo. `strip` is part of the profile and the
  # profile is hashed into every unit's fingerprint, so the dependency-only
  # build below has to agree or nothing it produces is reused.
  cargoEnv = {
    RUSTFLAGS = rustflags;
    CARGO_BUILD_TARGET = pkgs.stdenv.hostPlatform.rust.rustcTarget;
    CARGO_PROFILE_RELEASE_STRIP = "false";
  };

  # Common wiring for every Rust derivation here: the vendored sources above
  # and, when `cargoArtifacts` is given, the pre-built target directory.
  buildRustPackage =
    args:
    rustPlatform.buildRustPackage (
      args
      // {
        src = args.src or src;

        # Relative to the source root, where postUnpack links it into place.
        cargoVendorDir = "vendor";

        postUnpack = ''
          ln -s ${vendorDir} "$sourceRoot/vendor"
        ''
        + (args.postUnpack or "");

        # Its per-target rustflags conflict with the ones set below, and cargo
        # folds the resolved config into every unit's fingerprint, so both
        # sides of the dependency split have to drop it alike.
        postPatch = ''
          rm -f .cargo/config.toml
        ''
        + (args.postPatch or "");

        # The pinned toolchain goes first: `buildRustPackage` appends its own
        # cargo last, so anything in `args.nativeBuildInputs` that propagates a
        # cargo of its own would shadow it. `cargo-tauri` propagates one, and a
        # cargo version mismatch between this build and the dependency-only one
        # makes cargo reject every artifact with `ConfigSettingsChanged`.
        nativeBuildInputs = [
          toolchain
        ]
        ++ (args.nativeBuildInputs or [ ])
        ++ [
          pkgs.rsync
          pkgs.zstd
        ]
        ++ lib.optionals (args ? cargoArtifacts) [
          craneLib.inheritCargoArtifactsHook
          pkgs.removeReferencesTo
        ];

        env = cargoEnv // (args.env or { });
      }
      # Reading the vendored sources straight from the store (rather than from
      # a copy in the build tree, as `cargoDeps` would) bakes their paths into
      # the binaries via panic strings, so Nix keeps the whole ~1G of crate
      # sources as a runtime dependency of the package.
      #
      # Set only where it applies, so the dependency-only build's derivation
      # stays untouched: its output is a compressed archive that legitimately
      # contains those paths, and rewriting bytes inside it would corrupt it.
      // lib.optionalAttrs (args ? cargoArtifacts) {
        postInstall = (args.postInstall or "") + ''
          find "$out" -type f -exec remove-references-to -t ${craneVendorDir} '{}' +
        '';
      }
    );

  # Dependency-only build of one workspace member.
  #
  # `buildRustPackage` compiles the whole dependency graph inside the package
  # derivation, whose hash covers all of rust/, so any source change recompiles
  # ~900 crates from scratch and the binary cache never helps. crane's
  # `mkDummySrc` stubs out every workspace member, leaving the manifests,
  # Cargo.lock and .cargo/config.toml, so the same graph can be compiled by a
  # derivation that ignores ordinary source changes and is substituted from the
  # cache instead.
  #
  # Deliberately still `buildRustPackage`: cargo folds the resolved cargo
  # config into every unit's fingerprint, and `cargoSetupHook` writes a
  # `[target.<triple>]` block of its own. Anything that assembled the build
  # differently would have to reproduce that block to be reusable.
  #
  # Scoped per member rather than once for the whole workspace: the resolver
  # unifies features across all members of a `--workspace` build, and artifacts
  # compiled under a different feature set get recompiled anyway.
  cargoArtifactsFor =
    args:
    buildRustPackage (
      args
      // {
        pname = "${args.pname}-deps";
        # Deliberately fixed: `versions` below moves on every release, and
        # naming these after it would miss the cache each time.
        version = "0";

        src = craneLib.mkDummySrc { inherit src; };

        nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
          craneLib.installCargoArtifactsHook
        ];

        # Only the target directory is wanted; the stub binaries are garbage.
        doInstallCargoArtifacts = true;
        dontCargoInstall = true;
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          runHook postInstall
        '';
      }
    );

  # Current released version of each component we package. Read from the
  # sentinel comments here (kept in sync by scripts/bump-versions.sh) rather
  # than from Cargo.toml, whose `version` tracks the next, in-development
  # release.
  versions = {
    # mark:current-gateway-version
    gateway = "1.6.0";

    # mark:current-headless-version
    headless = "1.5.11";

    # mark:current-gui-version
    gui = "1.5.16";
  };

  meta = {
    homepage = "https://www.firezone.dev";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
