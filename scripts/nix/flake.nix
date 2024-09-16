{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { nixpkgs, flake-utils, rust-overlay, ... } @ inputs:
    flake-utils.lib.eachDefaultSystem
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };
          rust-nightly = pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default);

          # Wrap `cargo-udeps` to ensure it uses a nightly Rust version.
          cargo-udeps = pkgs.writeShellScriptBin "cargo-udeps" ''
            export RUSTC="${rust-nightly}/bin/rustc";
            export CARGO="${rust-nightly}/bin/cargo";
            exec "${pkgs.cargo-udeps}/bin/cargo-udeps" "$@"
          '';

          libraries = with pkgs; [
            webkitgtk
            gtk3
            cairo
            gdk-pixbuf
            glib
            dbus
            openssl_3
            librsvg
            libappindicator-gtk3
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
            gnome.zenity
            desktop-file-utils
            android-tools
            erlang_27
            elixir
          ];

          mkShellWithRustVersion = rustVersion: pkgs.mkShell {
            packages = [ pkgs.cargo-tauri pkgs.iptables pkgs.nodePackages.pnpm cargo-udeps pkgs.cargo-sort ];
            buildInputs = packages ++ [
              (rustVersion.override {
                extensions = [ "rust-src" "rust-analyzer" ];
                targets = [ "x86_64-unknown-linux-musl" ];
              })
            ];
            name = "rust-env";
            src = ../../rust;

            LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath libraries}:$LD_LIBRARY_PATH${pkgs.lib.makeLibraryPath libraries}:$LD_LIBRARY_PATH";
            XDG_DATA_DIRS = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS";
          };
        in
        {
          devShells.default = mkShellWithRustVersion (pkgs.rust-bin.fromRustupToolchainFile ../../rust/rust-toolchain.toml);
          devShells.nightly = mkShellWithRustVersion rust-nightly;
        }
      );
}
