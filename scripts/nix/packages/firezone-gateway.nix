{ lib, fzLib }:

fzLib.rustPlatform.buildRustPackage {
  pname = "firezone-gateway";
  version = fzLib.versions.gateway;

  inherit (fzLib) src cargoLock;

  buildAndTestSubdir = "gateway";

  env.RUSTFLAGS = fzLib.rustflags;

  postPatch = ''
    rm .cargo/config.toml
  '';

  meta = fzLib.meta // {
    description = "Gateway for the Firezone zero-trust access platform";
    mainProgram = "firezone-gateway";
  };
}
