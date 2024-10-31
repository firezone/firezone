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

            # For Tauri
            at-spi2-atk
            atkmm
            cairo
            gdk-pixbuf
            glib
            gobject-introspection
            gobject-introspection.dev
            gtk3
            harfbuzz
            librsvg
            libsoup_3
            pango
            webkitgtk_4_1
            webkitgtk_4_1.dev
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

            PKG_CONFIG_PATH = with pkgs; "${glib.dev}/lib/pkgconfig:${libsoup_3.dev}/lib/pkgconfig:${webkitgtk_4_1.dev}/lib/pkgconfig:${at-spi2-atk.dev}/lib/pkgconfig:${gtk3.dev}/lib/pkgconfig:${gdk-pixbuf.dev}/lib/pkgconfig:${cairo.dev}/lib/pkgconfig:${pango.dev}/lib/pkgconfig:${harfbuzz.dev}/lib/pkgconfig";
          };
        in
        {
          devShells.default = mkShellWithRustVersion (pkgs.rust-bin.fromRustupToolchainFile ../../rust/rust-toolchain.toml);
          devShells.nightly = mkShellWithRustVersion rust-nightly;
        }
      );
}
