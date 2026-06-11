{ lib, fzLib }:

fzLib.rustPlatform.buildRustPackage {
  pname = "firezone-headless-client";
  version = fzLib.crateVersion "headless-client";

  inherit (fzLib) src cargoLock;

  buildAndTestSubdir = "headless-client";

  env.RUSTFLAGS = fzLib.rustflags;

  postPatch = ''
    rm .cargo/config.toml
  '';

  preCheck = ''
    export XDG_RUNTIME_DIR=$(mktemp -d)
  '';

  meta = fzLib.meta // {
    description = "Headless Linux client for the Firezone zero-trust access platform";
    mainProgram = "firezone-headless-client";
  };
}
