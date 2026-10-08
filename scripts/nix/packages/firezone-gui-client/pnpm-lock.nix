# Rewrites a pnpm v9 lockfile so that every package resolves to a local
# tarball fetched by its own fixed-output `fetchurl`, keyed by the lockfile's
# integrity hash. `pnpm install --offline --frozen-lockfile` then needs no
# network and no aggregate dependency hash.
{
  lib,
  fetchurl,
  writeText,
}:
lockfile:
let
  text = builtins.readFile lockfile;
  section = lib.head (
    lib.splitString "\nsnapshots:\n" (lib.last (lib.splitString "\npackages:\n" text))
  );
  blocks = lib.filter (b: b != "") (lib.splitString "\n\n" section);

  parse =
    block:
    let
      lines = lib.filter (l: l != "") (lib.splitString "\n" block);
      m = builtins.match "  '?([^']+)@([^@']+)'?:    resolution: [{]integrity: ([^,}]+)[}]" (
        lib.concatStrings (lib.take 2 lines)
      );
    in
    if m == null then
      throw "pnpm-lock.nix: unsupported lockfile entry:\n${block}"
    else
      let
        name = lib.elemAt m 0;
        version = lib.elemAt m 1;
        integrity = lib.elemAt m 2;
        baseName = lib.last (lib.splitString "/" name);
      in
      lib.nameValuePair "{integrity: ${integrity}}" "{integrity: ${integrity}, tarball: file:${
        fetchurl {
          name = "${baseName}-${version}.tgz";
          url = "https://registry.npmjs.org/${name}/-/${baseName}-${version}.tgz";
          hash = integrity;
        }
      }}";

  replacements = builtins.listToAttrs (map parse blocks);
in
writeText "pnpm-lock.yaml" (
  builtins.replaceStrings (lib.attrNames replacements) (lib.attrValues replacements) text
)
