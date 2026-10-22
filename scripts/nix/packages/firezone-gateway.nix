{ lib, fzLib }:

let
  # Shared with the dependency-only build so the two cannot drift: cargo
  # reuses artifacts only for an identical invocation.
  common = {
    pname = "firezone-gateway";
    buildAndTestSubdir = "gateway";
  };
in
fzLib.buildRustPackage (
  common
  // {
    version = fzLib.versions.gateway;

    cargoArtifacts = fzLib.cargoArtifactsFor common;

    meta = fzLib.meta // {
      description = "Gateway for the Firezone zero-trust access platform";
      mainProgram = "firezone-gateway";
    };
  }
)
