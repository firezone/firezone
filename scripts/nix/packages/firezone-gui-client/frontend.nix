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
    # The only maintained hash in the Nix packaging. It changes whenever
    # gui-client/pnpm-lock.yaml does. The Nix build recomputes it on the fly
    # when it drifts (so CI/CD never fails on a stale pin) and opens a
    # firezone-bot PR to commit the new value; run
    # scripts/nix/update-pnpm-hash.sh to refresh it by hand.
    hash = "sha256-2XSe+Wjn0W0nLDOqGsKxre8SFRvvOSUX+/Q1flvevyA=";
  };

  # nixpkgs packages pnpm by major version only, not the exact patch in
  # rust/.tool-versions. Bump pnpm_10 here if that file's pnpm major changes.
  nativeBuildInputs = [
    nodejs
    pnpm_10
    pnpmConfigHook
  ];

  env = {
    # pnpm must know that Nix builds are non-interactive before it refreshes
    # node_modules from the fixed-output store.
    CI = "true";
    # Printed on the About page. vite.config.ts otherwise shells out to
    # `git rev-parse`, which the sandbox cannot do.
    GITHUB_SHA = if fzLib.rev == null then "unknown" else fzLib.rev;
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
