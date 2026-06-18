{ lib, fzLib }:

fzLib.rustPlatform.buildRustPackage {
  pname = "firezone-headless-client";
  version = fzLib.versions.headless;

  inherit (fzLib) src cargoLock;

  buildAndTestSubdir = "headless-client";

  env.RUSTFLAGS = fzLib.rustflags;

  postPatch = ''
    rm .cargo/config.toml
  '';

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
