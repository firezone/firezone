{
  lib,
  stdenv,
  fzLib,
  firezone-gui-client-frontend,
  cargo-tauri,
  pkg-config,
  wrapGAppsHook3,
  copyDesktopItems,
  makeDesktopItem,
  dbus,
  gdk-pixbuf,
  glib,
  gobject-introspection,
  gtk3,
  libayatana-appindicator,
  libsoup_3,
  openssl,
  webkitgtk_4_1,
  zenity,
  kdePackages,
}:

fzLib.rustPlatform.buildRustPackage {
  pname = "firezone-gui-client";
  version = fzLib.versions.gui;

  inherit (fzLib) src cargoLock;

  # The workspace Cargo.lock lives at the source root, so cargoRoot stays
  # unset; the Tauri hook cd's into the project via buildAndTestSubdir.
  buildAndTestSubdir = "gui-client/src-tauri";

  nativeBuildInputs = [
    cargo-tauri.hook
    pkg-config
    wrapGAppsHook3
    copyDesktopItems
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

  env = {
    RUSTFLAGS = fzLib.rustflags;
    # The tunnel daemon only accepts IPC connections from this exact
    # executable path (see gui-client/src-tauri/src/ipc/unix/peer_check).
    # wrapGAppsHook3 turns bin/firezone-client-gui into a shell wrapper, so
    # /proc/<pid>/exe of the running GUI resolves to the `.…-wrapped` ELF.
    FIREZONE_GUI_PEER_EXE = "${placeholder "out"}/bin/.firezone-client-gui-wrapped";
  };

  postPatch = ''
    rm .cargo/config.toml

    # frontendDist in tauri.conf.json points at ../dist; the checked-in
    # directory only holds a .gitkeep.
    rm -rf gui-client/dist
    ln -s ${firezone-gui-client-frontend} gui-client/dist

    # The Nix Tauri hook installs from the deb bundle, which copies the
    # tunnel binary from a path that assumes no --target triple in the
    # cargo target directory.
    substituteInPlace gui-client/src-tauri/tauri.conf.json \
      --replace-fail '../../target/release/firezone-client-tunnel' \
        '../../target/${stdenv.hostPlatform.rust.rustcTarget}/release/firezone-client-tunnel'
  '';

  # The workspace pulls Apple-specific crates into the test graph.
  doCheck = false;

  # wrapGAppsHook3 wraps every executable in $out/bin, which would stamp the
  # GUI-only --add-flags (notably --no-deep-links) onto the bundled
  # firezone-client-tunnel daemon, crashing it on startup with an
  # "unexpected argument '--no-deep-links'" error. Disable the blanket
  # wrapping and wrap only the GUI binary ourselves in postFixup.
  dontWrapGApps = true;

  postInstall = ''
    # register-sparse only does anything on Windows.
    rm -f $out/bin/register-sparse

    # Cargo names the binary after the crate (firezone-gui-client); the
    # packaged name everywhere else is the Tauri mainBinaryName.
    if [ -e $out/bin/firezone-gui-client ] && [ ! -e $out/bin/firezone-client-gui ]; then
      mv $out/bin/firezone-gui-client $out/bin/firezone-client-gui
    fi

    install -Dm644 gui-client/src-tauri/icons/32x32.png \
      $out/share/icons/hicolor/32x32/apps/firezone-client-gui.png
    install -Dm644 gui-client/src-tauri/icons/128x128.png \
      $out/share/icons/hicolor/128x128/apps/firezone-client-gui.png
    install -Dm644 "gui-client/src-tauri/icons/128x128@2x.png" \
      $out/share/icons/hicolor/256x256/apps/firezone-client-gui.png
  '';

  # dontWrapGApps disables the automatic wrapping, so wrap only the GUI
  # binary here. gappsWrapperArgs is populated in preFixup below.
  postFixup = ''
    wrapProgram $out/bin/firezone-client-gui "''${gappsWrapperArgs[@]}"
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "firezone-client-gui";
      desktopName = "Firezone";
      comment = "Firezone GUI Client";
      exec = "firezone-client-gui";
      icon = "firezone-client-gui";
      categories = [ "Network" ];
      terminal = false;
    })
    # Handler for the browser-based sign-in deep link.
    (makeDesktopItem {
      name = "firezone-client-gui-deep-link";
      desktopName = "Firezone deep-link handler";
      exec = "firezone-client-gui open-deep-link %U";
      icon = "firezone-client-gui";
      noDisplay = true;
      mimeTypes = [ "x-scheme-handler/firezone-fd0020211111" ];
    })
  ];

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix PATH : ${
        lib.makeBinPath [
          zenity
          kdePackages.kdialog
        ]
      }
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libayatana-appindicator ]}
      # Suppress runtime deep-link self-registration. On startup the GUI
      # otherwise writes a per-user handler pointing at the unwrapped
      # .firezone-client-gui-wrapped ELF, which overrides the packaged
      # wrapper-based handler and drops the wrapper environment on
      # cold-start callbacks. The packaged desktop item is the only
      # handler we want; this flag gates only registration, not callback
      # handling, so browser sign-in still works.
      --add-flags "--no-deep-links"
    )
  '';

  meta = fzLib.meta // {
    description = "GUI client for the Firezone zero-trust access platform";
    mainProgram = "firezone-client-gui";
  };
}
