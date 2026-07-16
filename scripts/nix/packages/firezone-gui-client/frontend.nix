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
    hash = "sha256-o6i7CyklAajY+WEgk8A7MtV8oSiKrZeLDDeLz9WyVjY=";
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
