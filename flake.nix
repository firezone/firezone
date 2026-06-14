{
  description = "Firezone, a zero-trust access platform built on WireGuard";

  # Convenience hints for the first-party binary cache. Nix only honors these
  # for trusted users (or with --accept-flake-config); the docs in scripts/nix/README.md
  # lead with the explicit `nix.settings` form.
  nixConfig = {
    extra-substituters = [ "https://artifacts.firezone.dev/nix" ];
    extra-trusted-public-keys = [ "artifacts.firezone.dev/nix-1:T4LHdL1HeA6LE9qgu0Po0j3RIlelKZz8pzqnzEAIRfI=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      inherit (nixpkgs) lib;

      # The data plane components are Linux-only; macOS has a native app.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      pkgsFor = lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        }
      );

      forAllSystems = f: lib.genAttrs systems (system: f pkgsFor.${system});
    in
    {
      overlays.default = lib.composeManyExtensions [
        rust-overlay.overlays.default
        (import ./scripts/nix/overlay.nix)
      ];

      packages = forAllSystems (pkgs: {
        inherit (pkgs)
          firezone-gateway
          firezone-headless-client
          firezone-gui-client
          ;
        default = pkgs.firezone-headless-client;
      });

      nixosModules = {
        gateway = import ./scripts/nix/modules/gateway.nix self;
        headless-client = import ./scripts/nix/modules/headless-client.nix self;
        gui-client = import ./scripts/nix/modules/gui-client.nix self;
        default = {
          imports = [
            self.nixosModules.gateway
            self.nixosModules.headless-client
            self.nixosModules.gui-client
          ];
        };
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.callPackage ./scripts/nix/devshell.nix { };
      });

      checks = forAllSystems (
        pkgs:
        {
          inherit (pkgs)
            firezone-gateway
            firezone-headless-client
            firezone-gui-client
            ;
        }
        // import ./scripts/nix/checks.nix {
          inherit self nixpkgs pkgs;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
