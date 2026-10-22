{ lib, fzLib }:

let
  # Shared with the dependency-only build so the two cannot drift: cargo
  # reuses artifacts only for an identical invocation.
  common = {
    pname = "firezone-headless-client";
    buildAndTestSubdir = "headless-client";
  };
in
fzLib.buildRustPackage (
  common
  // {
    version = fzLib.versions.headless;

    cargoArtifacts = fzLib.cargoArtifactsFor common;

    preCheck = ''
      export XDG_RUNTIME_DIR=$(mktemp -d)
    '';

    checkFlags = [
      # These chown the token file to root; the sandbox builds unprivileged.
      "--skip=tests::set_token_permissions_satisfies_check"
      "--skip=tests::token_roundtrip_write_and_read"
      "--skip=tests::write_token_creates_file_with_content"
      "--skip=tests::write_token_creates_parent_directories"
      "--skip=tests::write_token_overwrites_existing"
    ];

    meta = fzLib.meta // {
      description = "Headless Linux client for the Firezone zero-trust access platform";
      mainProgram = "firezone-headless-client";
    };
  }
)
