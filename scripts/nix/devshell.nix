# Everything `cargo build` / `pnpm` need to work on the Rust workspace on a
# NixOS host. Complements (does not replace) the mise-managed toolchain used
# on other platforms.
{
  mkShell,
  rust-bin,
  cargo-tauri,
  nodejs,
  pnpm_10,
  pkg-config,
  dbus,
  gdk-pixbuf,
  glib,
  gobject-introspection,
  gtk3,
  libayatana-appindicator,
  libsoup_3,
  openssl,
  webkitgtk_4_1,
}:

mkShell {
  packages = [
    (rust-bin.fromRustupToolchainFile ../../rust/rust-toolchain.toml)
    cargo-tauri
    nodejs
    pnpm_10
    pkg-config
  ];

  buildInputs = [
    dbus
    gdk-pixbuf
    glib
    gobject-introspection
    gtk3
    libayatana-appindicator
    libsoup_3
    openssl
    webkitgtk_4_1
  ];
}
