{
  stdenvNoCC,
  nodejs,
  pnpm_10,
  callPackage,
  fzLib,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "firezone-gui-client-frontend";
  version = fzLib.versions.gui;

  inherit (fzLib) src;
  sourceRoot = "rust/gui-client";

  pnpmLock = callPackage ./pnpm-lock.nix { } (fzLib.src + "/gui-client/pnpm-lock.yaml");

  # nixpkgs packages pnpm by major version only, not the exact patch in
  # rust/.tool-versions. Bump pnpm_10 here if that file's pnpm major changes.
  nativeBuildInputs = [
    nodejs
    pnpm_10
  ];

  # vite.config.ts falls back to `git rev-parse` when unset, which is
  # unavailable in the sandbox.
  env = {
    # pnpm must know that Nix builds are non-interactive before it refreshes
    # node_modules.
    CI = "true";
    GITHUB_SHA = finalAttrs.version;
    npm_config_manage_package_manager_versions = "false";
  };

  configurePhase = ''
    runHook preConfigure

    cp --no-preserve=mode $pnpmLock pnpm-lock.yaml
    export HOME=$TMPDIR
    pnpm install --offline --ignore-scripts --frozen-lockfile --store-dir "$TMPDIR/pnpm-store"
    patchShebangs node_modules/{*,.*}

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    pnpm exec vite build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    cp -r dist $out

    runHook postInstall
  '';

  meta = fzLib.meta // {
    description = "Web assets for the Firezone GUI client";
  };
})
