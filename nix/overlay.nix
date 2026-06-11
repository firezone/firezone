final: prev:
let
  fzLib = import ./lib.nix {
    inherit (final) lib;
    pkgs = final;
  };
in
{
  firezone-gateway = final.callPackage ./packages/firezone-gateway.nix { inherit fzLib; };

  firezone-headless-client = final.callPackage ./packages/firezone-headless-client.nix {
    inherit fzLib;
  };

  firezone-gui-client-frontend = final.callPackage ./packages/firezone-gui-client/frontend.nix {
    inherit fzLib;
  };

  firezone-gui-client = final.callPackage ./packages/firezone-gui-client/package.nix {
    inherit fzLib;
  };
}
