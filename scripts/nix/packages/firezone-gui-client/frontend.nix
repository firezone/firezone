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
  version = fzLib.versions.gui;

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
    # Refresh with scripts/nix/update-pnpm-hash.sh when pnpm-lock.yaml changes.
    # CI and GUI release drafting verify this pin without repairing it.
    hash = "sha256-xmr2F67I1y7v99sS7hQKgl5auc9jI+l7jiQjfa4wfw8=";
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
  env = {
    # pnpm must know that Nix builds are non-interactive before it refreshes
    # node_modules from the fixed-output store.
    CI = "true";
    GITHUB_SHA = finalAttrs.version;
  };

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
