{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.11";
    naersk.url = "github:nix-community/naersk";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, ... } @ inputs:
    flake-utils.lib.eachDefaultSystem
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };
          naersk = pkgs.callPackage inputs.naersk { };
          nativeBuildInputs = with pkgs; [ pkg-config glibc gtk3 gtk4 webkitgtk libsoup atk ];
        in

        {

          packages.firezone-linux-client = naersk.buildPackage {
            name = "foo";
            src = ../../rust/linux-client;
          };

          devShell = pkgs.mkShell {
            buildInputs = [
              (pkgs.rust-bin.fromRustupToolchainFile ../../rust/rust-toolchain.toml)
            ];
            inherit nativeBuildInputs;
            name = "rust-env";
            src = ../../rust;
          };
        }

      );
}
