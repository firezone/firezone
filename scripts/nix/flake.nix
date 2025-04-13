{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
            };
          };

          packages = with pkgs; [
            rustup # We use `rustup` to manage the Rust installation in order to get `+nightly` etc features.

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
            zenity
            desktop-file-utils
            android-tools
            terraform
            llvmPackages.bintools-unwrapped
            bpftools

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
        in
        {
          devShells.default = pkgs.mkShell {
            packages = [ pkgs.cargo-tauri pkgs.iptables pkgs.pnpm pkgs.cargo-sort pkgs.cargo-deny pkgs.cargo-autoinherit ];
            buildInputs = packages;
            src = ../..;

            PKG_CONFIG_PATH = with pkgs; "${glib.dev}/lib/pkgconfig:${libsoup_3.dev}/lib/pkgconfig:${webkitgtk_4_1.dev}/lib/pkgconfig:${at-spi2-atk.dev}/lib/pkgconfig:${gtk3.dev}/lib/pkgconfig:${gdk-pixbuf.dev}/lib/pkgconfig:${cairo.dev}/lib/pkgconfig:${pango.dev}/lib/pkgconfig:${harfbuzz.dev}/lib/pkgconfig";
          };
        }
      );
}
