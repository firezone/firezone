# Evaluation-level checks. The packages themselves are added to `checks`
# directly in flake.nix.
{
  self,
  nixpkgs,
  pkgs,
}:
let
  # Evaluates a NixOS system with all three modules enabled. Forcing the
  # toplevel drvPath catches option and module regressions during
  # `nix flake check --no-build` without building a full system.
  eval = nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      self.nixosModules.default
      {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = "25.11";

        services.resolved.enable = true;
        users.users.alice = {
          isNormalUser = true;
        };

        services.firezone.gateway = {
          enable = true;
          tokenFile = "/var/lib/secrets/gateway-token";
          nat.externalInterface = "eth0";
        };

        services.firezone.headless-client = {
          enable = true;
          tokenFile = "/var/lib/secrets/client-token";
        };

        services.firezone.gui-client = {
          enable = true;
          allowedUsers = [ "alice" ];
        };
      }
    ];
  };
in
{
  module-eval = builtins.seq eval.config.system.build.toplevel.drvPath (
    pkgs.runCommand "firezone-module-eval-ok" { } "touch $out"
  );
}
