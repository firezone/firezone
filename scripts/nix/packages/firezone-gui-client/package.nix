{
  lib,
  stdenv,
  fzLib,
  firezone-gui-client-frontend,
  installShellFiles,
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

let
  # Shared with the dependency-only build so the two cannot drift: cargo
  # reuses artifacts only for an identical invocation.
  common = {
    pname = "firezone-gui-client";

    # The workspace Cargo.lock lives at the source root, so cargoRoot stays
    # unset; buildAndTestSubdir picks the package to build.
    buildAndTestSubdir = "gui-client/src-tauri";

    # Embeds the frontend instead of loading it from the Vite dev server.
    buildFeatures = [ "tauri/custom-protocol" ];

    # The workspace pulls Apple-specific crates into the test graph.
    doCheck = false;

    nativeBuildInputs = [ pkg-config ];

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
  };
in
fzLib.buildRustPackage (
  common
  // {
    version = fzLib.versions.gui;

    cargoArtifacts = fzLib.cargoArtifactsFor common;

    nativeBuildInputs = common.nativeBuildInputs ++ [
      installShellFiles
      wrapGAppsHook3
      copyDesktopItems
    ];

    env = {
      # The tunnel daemon only accepts IPC connections from this exact
      # executable path (see gui-client/src-tauri/src/ipc/unix/peer_check).
      # wrapGAppsHook3 turns bin/firezone-client-gui into a shell wrapper, so
      # /proc/<pid>/exe of the running GUI resolves to the `.…-wrapped` ELF.
      FIREZONE_GUI_PEER_EXE = "${placeholder "out"}/bin/.firezone-client-gui-wrapped";

      # The GUI only accepts CLI connections from this exact executable path.
      # `dontWrapGApps` below leaves bin/firezone unwrapped, so the CLI's
      # /proc/<pid>/exe is the installed ELF itself.
      FIREZONE_CLI_PEER_EXE = "${placeholder "out"}/bin/firezone";
    };

    postPatch = ''
      # frontendDist in tauri.conf.json points at ../dist; the checked-in
      # directory only holds a .gitkeep.
      rm -rf gui-client/dist
      ln -s ${firezone-gui-client-frontend} gui-client/dist
    '';

    # The `firezone` CLI is a workspace member of its own, so the build of
    # buildAndTestSubdir never compiles it.
    preBuild = ''
      cargo build --release --offline -j $NIX_BUILD_CORES -p firezone-cli
    '';

    # wrapGAppsHook3 wraps every executable in $out/bin, which would stamp the
    # GUI-only --add-flags (notably --no-deep-links) onto the bundled
    # firezone-client-tunnel daemon, crashing it on startup with an
    # "unexpected argument '--no-deep-links'" error. Disable the blanket
    # wrapping and wrap only the GUI binary ourselves in postFixup.
    dontWrapGApps = true;

    postInstall = ''
      # register-sparse only does anything on Windows.
      rm -f $out/bin/register-sparse

      # The names the Linux packages install them under.
      mv $out/bin/firezone-gui-client $out/bin/firezone-client-gui
      mv $out/bin/firezone-cli $out/bin/firezone

      install -Dm644 gui-client/src-tauri/icons/32x32.png \
        $out/share/icons/hicolor/32x32/apps/firezone-client-gui.png
      install -Dm644 gui-client/src-tauri/icons/128x128.png \
        $out/share/icons/hicolor/128x128/apps/firezone-client-gui.png
      install -Dm644 "gui-client/src-tauri/icons/128x128@2x.png" \
        $out/share/icons/hicolor/256x256/apps/firezone-client-gui.png
      install -Dm644 gui-client/src-tauri/icons/icon.png \
        $out/share/icons/hicolor/512x512/apps/firezone-client-gui.png
      install -Dm644 gui-client/src-tauri/linux_package/dev.firezone.client.metainfo.xml \
        $out/share/metainfo/dev.firezone.client.metainfo.xml

      completions=target/${stdenv.hostPlatform.rust.rustcTarget}/release/completions
      installShellCompletion --cmd firezone \
        --bash $completions/firezone.bash \
        --zsh $completions/_firezone \
        --fish $completions/firezone.fish
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
)
