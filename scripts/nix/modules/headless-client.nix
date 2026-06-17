# NixOS module for the Firezone headless client. Adapted from
# scripts/tests/systemd/firezone-client-headless.service.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.firezone.headless-client;
in
{
  # nixpkgs ships a community-maintained module under the same option
  # namespace; this first-party module supersedes it.
  disabledModules = [ "services/networking/firezone/headless-client.nix" ];

  options.services.firezone.headless-client = {
    enable = lib.mkEnableOption "the Firezone headless client";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.firezone-headless-client;
      defaultText = lib.literalExpression "firezone.packages.<system>.firezone-headless-client";
      description = "The firezone-headless-client package to use.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      example = "/var/lib/secrets/firezone-client-token";
      description = ''
        Path to a file containing a service account token issued by the
        admin portal. Passed to the service via systemd credentials; must
        not live in the Nix store.
      '';
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Friendly name for this client as shown in the admin portal.";
    };

    id = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Unique identifier for this client. When null, the client
        generates and persists one under its state directory.
      '';
    };

    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "wss://api.firezone.dev/";
      description = "WebSocket URL of the Firezone control plane API.";
    };

    dnsControl = lib.mkOption {
      type = lib.types.enum [
        "systemd-resolved"
        "etc-resolv-conf"
        "disabled"
      ];
      default = "systemd-resolved";
      description = "Mechanism the client uses to take control of system DNS.";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "RUST_LOG directives for the client.";
    };

    enableTelemetry = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to allow crash reporting and telemetry.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the client (FIREZONE_*).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dnsControl != "systemd-resolved" || config.services.resolved.enable;
        message = "services.firezone.headless-client.dnsControl = \"systemd-resolved\" requires services.resolved.enable = true";
      }
    ];

    systemd.services.firezone-headless-client = {
      description = "Firezone headless client";
      documentation = [ "https://www.firezone.dev/kb" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optional (cfg.dnsControl == "systemd-resolved") "systemd-resolved.service";
      wants = [
        "network-online.target"
      ]
      ++ lib.optional (cfg.dnsControl == "systemd-resolved") "systemd-resolved.service";
      wantedBy = [ "multi-user.target" ];

      # DNS control shells out to resolvectl.
      path = [ pkgs.systemd ];

      environment = {
        FIREZONE_API_URL = cfg.apiUrl;
        FIREZONE_NAME = cfg.name;
        FIREZONE_DNS_CONTROL = cfg.dnsControl;
        # Credential files are root-owned with mode 0400, satisfying the
        # client's token file permission checks.
        FIREZONE_TOKEN_PATH = "%d/firezone-token";
        RUST_LOG = cfg.logLevel;
      }
      // lib.optionalAttrs (cfg.id != null) { FIREZONE_ID = cfg.id; }
      // lib.optionalAttrs (!cfg.enableTelemetry) { FIREZONE_NO_TELEMETRY = "true"; }
      // cfg.extraEnvironment;

      serviceConfig = {
        Type = "notify";
        ExecStart = lib.getExe cfg.package;
        # Root is required to control DNS.
        User = "root";

        LoadCredential = [ "firezone-token:${cfg.tokenFile}" ];

        # No TimeoutStartSec: this Type=notify unit only sends READY=1
        # after the first tunnel-up, which can take a while on slow
        # portals. Rely on systemd's 90s default rather than risk a
        # restart loop on a client that is still making progress.
        TimeoutStopSec = "15s";
        Restart = "always";
        RestartSec = 7;

        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        DeviceAllow = [ "/dev/net/tun" ];
        StateDirectory = "dev.firezone.client";
        RuntimeDirectory = "dev.firezone.client";

        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateMounts = true;
        PrivateTmp = true;
        # We need to be real root, not just root in our cgroup.
        PrivateUsers = false;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        # etc-resolv-conf mode rewrites /etc/resolv.conf in place and
        # atomic-writes a backup as a temp sibling in /etc, both of which
        # need /etc writable under ProtectSystem = "strict".
        ReadWritePaths = lib.optionals (cfg.dnsControl == "etc-resolv-conf") [ "/etc" ];
        # Netlink for the tunnel interface, Unix for systemd-resolved.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@aio"
          "@basic-io"
          "@file-system"
          "@io-event"
          "@network-io"
          "@signal"
          "@system-service"
        ];
        UMask = "077";
      };
    };
  };
}
