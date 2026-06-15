{
  stdenvNoCC,
  nodejs,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  fzLib,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "firezone-gui-client-frontend";
  version = fzLib.crateVersion "gui-client/src-tauri";

  inherit (fzLib) src;
  sourceRoot = "rust/gui-client";

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs)
      pname
      version
      src
      sourceRoot
      ;
    pnpm = pnpm_10;
    fetcherVersion = 4;
    # The only maintained hash in the Nix packaging. It changes only when
    # gui-client/pnpm-lock.yaml changes; the build failure message contains
    # the new value.
    hash = "sha256-IflKPJMznh7xIpUfAHdw+pfNQ7n5Rx1fmPyLqjdaneM=";
  };

  # nixpkgs packages pnpm by major version only, not the exact patch in
  # rust/.tool-versions. Bump pnpm_10 here if that file's pnpm major changes.
  nativeBuildInputs = [
    nodejs
    pnpm_10
    pnpmConfigHook
  ];

  # vite.config.ts falls back to `git rev-parse` when unset, which is
  # unavailable in the sandbox.
  env.GITHUB_SHA = finalAttrs.version;

  buildPhase = ''
    runHook preBuild

    # pnpm.configHook installs with --ignore-scripts; replicate the
    # `postinstall` script from package.json before bundling.
    pnpm exec flowbite-react build
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
