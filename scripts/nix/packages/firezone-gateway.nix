{ lib, fzLib }:

fzLib.buildRustPackage {
  pname = "firezone-gateway";
  version = fzLib.versions.gateway;

  cargoArtifacts = fzLib.cargoArtifactsFor { crate = "firezone-gateway"; };

  buildAndTestSubdir = "gateway";

  postPatch = ''
    rm .cargo/config.toml
  '';

  meta = fzLib.meta // {
    description = "Gateway for the Firezone zero-trust access platform";
    mainProgram = "firezone-gateway";
  };
}
