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

          libraries = with pkgs;[
            webkitgtk
            gtk3
            cairo
            gdk-pixbuf
            glib
            dbus
            openssl_3
            librsvg
          ];

          packages = with pkgs; [
            curl
            wget
            pkg-config
            dbus
            openssl_3
            glib
            gtk3
            libsoup
            webkitgtk
            librsvg
            libappindicator-gtk3
          ];
        in

        {

          packages.firezone-linux-client = naersk.buildPackage {
            name = "foo";
            src = ../../rust/linux-client;
          };

          devShell = pkgs.mkShell {
            packages = [ pkgs.cargo-tauri ];
            buildInputs = [
              (pkgs.rust-bin.fromRustupToolchainFile ../../rust/rust-toolchain.toml)
            ] ++ packages;
            name = "rust-env";
            src = ../../rust;
            shellHook =
              ''
                export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath libraries}:$LD_LIBRARY_PATH
                export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS
              '';
          };
        }

      );
}
