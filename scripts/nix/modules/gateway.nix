# NixOS module for the Firezone Gateway. Adapted from
# rust/gateway/debian/firezone-gateway.service and
# rust/gateway/debian/firezone-gateway-init.sh.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.firezone.gateway;
in
{
  # nixpkgs ships a community-maintained module under the same option
  # namespace; this first-party module supersedes it.
  disabledModules = [ "services/networking/firezone/gateway.nix" ];

  options.services.firezone.gateway = {
    enable = lib.mkEnableOption "the Firezone Gateway";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.firezone-gateway;
      defaultText = lib.literalExpression "firezone.packages.<system>.firezone-gateway";
      description = "The firezone-gateway package to use.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      example = "/var/lib/secrets/firezone-gateway-token";
      description = ''
        Path to a file containing the Gateway token issued by the admin
        portal. Passed to the service via systemd credentials; must not
        live in the Nix store.
      '';
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Friendly name for this Gateway as shown in the admin portal.";
    };

    id = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Unique identifier for this Gateway. When null, a deterministic ID
        is derived from /etc/machine-id.
      '';
    };

    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "wss://api.firezone.dev/";
      description = "WebSocket URL of the Firezone control plane API.";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "RUST_LOG directives for the Gateway.";
    };

    enableTelemetry = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to allow crash reporting and telemetry.";
    };

    nat = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Configure NAT masquerading for tunnel traffic via
          networking.nat. Disable to manage masquerading yourself.
          Packet-forwarding sysctls are applied unconditionally because
          the Gateway requires forwarding to route at all; override them
          via boot.kernel.sysctl if you manage forwarding yourself.
        '';
      };

      externalInterface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "eth0";
        description = ''
          Interface tunnel traffic is masqueraded out of. May be left
          null if networking.nat.externalInterface is already set.
        '';
      };
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the Gateway (FIREZONE_*).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !cfg.nat.enable
          || cfg.nat.externalInterface != null
          || config.networking.nat.externalInterface != null;
        message = "services.firezone.gateway.nat.enable requires services.firezone.gateway.nat.externalInterface (or networking.nat.externalInterface) to be set";
      }
    ];

    # The Gateway routes client traffic to Resources, so IP forwarding is
    # always required, independent of nat.enable. These are mkDefault so a
    # user who manages forwarding themselves can still override them.
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "net.ipv4.conf.all.src_valid_mark" = lib.mkDefault 1;
      "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
      "net.ipv6.conf.default.forwarding" = lib.mkDefault 1;
    };

    networking.nat = lib.mkIf cfg.nat.enable {
      enable = true;
      enableIPv6 = lib.mkDefault true;
      internalInterfaces = [ "tun-firezone" ];
      externalInterface = lib.mkIf (cfg.nat.externalInterface != null) (
        lib.mkDefault cfg.nat.externalInterface
      );
    };

    systemd.services.firezone-gateway = {
      description = "Firezone Gateway";
      documentation = [ "https://www.firezone.dev/kb" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        FIREZONE_API_URL = cfg.apiUrl;
        FIREZONE_NAME = cfg.name;
        RUST_LOG = cfg.logLevel;
      }
      // lib.optionalAttrs (cfg.id != null) { FIREZONE_ID = cfg.id; }
      // lib.optionalAttrs (!cfg.enableTelemetry) { FIREZONE_NO_TELEMETRY = "true"; }
      // cfg.extraEnvironment;

      # The Gateway reads $CREDENTIALS_DIRECTORY/FIREZONE_TOKEN natively
      # when FIREZONE_TOKEN is unset, so the token never enters the
      # environment.
      # Derive the same deterministic ID the deb/rpm packages use and pass
      # it explicitly. The binary can self-derive from /etc/machine-id, but
      # only after create_dir_all("/var/lib/firezone"), which this hardened
      # unit (DynamicUser, ProtectSystem = "strict", no StateDirectory)
      # forbids, so it would fail to start. Precomputing keeps it stateless.
      script = ''
        ${lib.optionalString (cfg.id == null) ''
          FIREZONE_ID="$(${pkgs.systemd}/bin/systemd-id128 --app-specific=753b38f9f96947ef8083802d5909a372 machine-id)"
          export FIREZONE_ID
        ''}
        exec ${lib.getExe cfg.package}
      '';

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        User = "firezone-gateway";
        SyslogIdentifier = "firezone-gateway";

        LoadCredential = [ "FIREZONE_TOKEN:${cfg.tokenFile}" ];

        TimeoutStartSec = "15s";
        TimeoutStopSec = "15s";
        Restart = "always";
        RestartSec = 7;

        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        DeviceAllow = [ "/dev/net/tun" ];

        LimitNOFILE = 4096;
        LimitNPROC = 512;
        LimitCORE = 0;

        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
      };
    };
  };
}
