# Everything `cargo build` needs to work on the Rust workspace on a
# NixOS host. Complements (does not replace) the mise-managed toolchain used
# on other platforms.
{
  mkShell,
  rust-bin,
  pkg-config,
  dbus,
  fontconfig,
  freetype,
  libGL,
  openssl,
  wayland,
}:

mkShell {
  packages = [
    (rust-bin.fromRustupToolchainFile ../../rust/rust-toolchain.toml)
    pkg-config
  ];

  buildInputs = [
    dbus
    fontconfig
    freetype
    libGL
    openssl
    wayland
  ];
}
