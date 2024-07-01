{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.11";
    naersk.url = "github:nix-community/naersk";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    android.url = "github:tadfisher/android-nixpkgs";
    gradle2nix.url = "github:tadfisher/gradle2nix/v2";
  };

  outputs = { nixpkgs, flake-utils, rust-overlay, android, gradle2nix, ... } @ inputs:
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

          gradle2nixBin = gradle2nix.packages.${system}.default;

          android-sdk = android.sdk.${system} (sdkPkgs: with sdkPkgs; [
            build-tools-34-0-0
            cmdline-tools-latest
            # emulator
            platform-tools
            platforms-android-34
            ndk-25-2-9519653 # Needs to match what is defined in `kotlin/android/app/build.gradle.kts`
          ]);
          jdk = pkgs.zulu17;

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

          pinnedRust = pkgs.rust-bin.fromRustupToolchainFile ../../rust/rust-toolchain.toml;

          mkShellWithRustVersion = rustVersion: pkgs.mkShell {
            packages = [
              pkgs.cargo-tauri
              pkgs.iptables
              pkgs.nodePackages.pnpm
              cargo-udeps
              gradle2nixBin
              android-sdk
              jdk
            ];
            buildInputs = rustVersion ++ packages;
            name = "rust-env";
            src = ../../rust;
            shellHook =
              ''
                export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath libraries}:$LD_LIBRARY_PATH
                export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS
              '';
            env = [
              "NDK_HOME=${android-sdk}/share/android-sdk/ndk/25.2.9519653"
              "ANDROID_HOME=${android-sdk}/share/android-sdk"
              "ANDROID_SDK_ROOT=${android-sdk}/share/android-sdk"
              "JAVA_HOME=${jdk.home}"
            ];
          };
        in
        {
          packages.firezone-android-debug = gradle2nix.builders.${system}.buildGradlePackage
            {
              pname = "firezone-android";
              # mark:next-android-version
              version = "1.1.2";
              src = ../../kotlin/android;
              lockFile = ../../kotlin/android/gradle.lock;
              gradleInstallFlags = [ "--stacktrace bundleDebug" ];

              NDK_HOME = "${android-sdk}/share/android-sdk/ndk/25.2.9519653";
              ANDROID_HOME = "${android-sdk}/share/android-sdk";
              ANDROID_SDK_ROOT = "${android-sdk}/share/android-sdk";
              JAVA_HOME = "${jdk.home}";

              buildInputs = [
                (pinnedRust.override
                  {
                    targets = [
                      "aarch64-linux-android"
                      "arm-linux-androideabi"
                      "armv7-linux-androideabi"
                      "i686-linux-android"
                      "x86_64-linux-android"
                    ];
                  })
              ];
            };

          devShells.default = mkShellWithRustVersion
            [
              pinnedRust
            ];

          devShells.nightly = mkShellWithRustVersion
            [
              (pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default))
            ];
        }
      );
}
