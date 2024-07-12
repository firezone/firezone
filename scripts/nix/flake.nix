{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.11";
    naersk.url = "github:nix-community/naersk";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    android.url = "github:tadfisher/android-nixpkgs";
  };

  outputs = { nixpkgs, flake-utils, rust-overlay, android, ... } @ inputs:
    flake-utils.lib.eachDefaultSystem
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };
          naersk = pkgs.callPackage inputs.naersk { };
          rust-nightly = pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default);

          # Wrap `cargo-udeps` to ensure it uses a nightly Rust version.
          cargo-udeps = pkgs.writeShellScriptBin "cargo-udeps" ''
            export RUSTC="${rust-nightly}/bin/rustc";
            export CARGO="${rust-nightly}/bin/cargo";
            exec "${pkgs.cargo-udeps}/bin/cargo-udeps" "$@"
          '';

          libraries = with pkgs;[
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
          ];

          android-sdk = android.sdk.${system} (sdkPkgs: with sdkPkgs; [
            build-tools-34-0-0
            cmdline-tools-latest
            # emulator
            platform-tools
            platforms-android-34
            ndk-25-2-9519653 # Needs to match what is defined in `kotlin/android/app/build.gradle.kts`
          ]);
          jdk = pkgs.zulu17;

          pinnedRust = pkgs.rust-bin.fromRustupToolchainFile ../../rust/rust-toolchain.toml;

          androidEnv = pkgs.buildFHSUserEnv {
            name = "android-env";
            targetPkgs = pkgs: (with pkgs; [
              glibc
              zlib
              jdk
              android-sdk
            ]);
            profile = ''
              export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath (with pkgs; [ glibc zlib ])}:$LD_LIBRARY_PATH
              export NDK_HOME="${android-sdk}/share/android-sdk/ndk/25.2.9519653";
              export ANDROID_HOME="${android-sdk}/share/android-sdk";
              export ANDROID_SDK_ROOT="${android-sdk}/share/android-sdk";
              export JAVA_HOME="${jdk.home}";
            '';
          };

          gradleWrapper = pkgs.writeShellScriptBin "gradleWrapper" ''
              export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath (with pkgs; [ glibc zlib ])}:$LD_LIBRARY_PATH
              export NDK_HOME="${android-sdk}/share/android-sdk/ndk/25.2.9519653";
              export ANDROID_HOME="${android-sdk}/share/android-sdk";
              export ANDROID_SDK_ROOT="${android-sdk}/share/android-sdk";
              export JAVA_HOME="${jdk.home}";

            ${androidEnv}/bin/android-env ./gradlew "$@"
          '';

          mkShellWithRustVersion = rustVersion: pkgs.mkShell {
            packages = [ pkgs.cargo-tauri pkgs.iptables pkgs.nodePackages.pnpm cargo-udeps gradleWrapper ];
            buildInputs = rustVersion ++ packages;
            name = "rust-env";
            src = ../../rust;
            shellHook =
              ''
                export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath libraries}:$LD_LIBRARY_PATH
                export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS
              '';
          };
        in
        {
          devShells.default = mkShellWithRustVersion [
            (pinnedRust.override {
              targets = [
                "aarch64-linux-android"
                "arm-linux-androideabi"
                "armv7-linux-androideabi"
                "i686-linux-android"
                "x86_64-linux-android"
              ];
            })
          ];

          devShells.nightly = mkShellWithRustVersion [
            (pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default))
          ];
        }
      );
}
