# NixOS module for the Firezone GUI client. The privileged tunnel daemon
# is adapted from rust/gui-client/src-tauri/linux_package/
# firezone-client-tunnel.service; the GUI itself runs in the user's
# desktop session.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.firezone.gui-client;
in
{
  # nixpkgs ships a community-maintained module under the same option
  # namespace; this first-party module supersedes it.
  disabledModules = [ "services/networking/firezone/gui-client.nix" ];

  options.services.firezone.gui-client = {
    enable = lib.mkEnableOption "the Firezone GUI client";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.firezone-gui-client;
      defaultText = lib.literalExpression "firezone.packages.<system>.firezone-gui-client";
      description = "The firezone-gui-client package to use.";
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        Users allowed to control the tunnel daemon. They are added to the
        firezone-client group, which may connect to the daemon's IPC
        socket.
      '';
    };

    dnsControl = lib.mkOption {
      type = lib.types.enum [
        "systemd-resolved"
        "etc-resolv-conf"
        "disabled"
      ];
      default = "systemd-resolved";
      description = "Mechanism the tunnel daemon uses to take control of system DNS.";
    };

    provisionKeyring = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable gnome-keyring as a Secret Service provider for storing the
        session token. Disable if your desktop already provides one (e.g.
        KWallet on Plasma).
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the tunnel daemon (FIREZONE_*).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dnsControl != "systemd-resolved" || config.services.resolved.enable;
        message = "services.firezone.gui-client.dnsControl = \"systemd-resolved\" requires services.resolved.enable = true";
      }
    ];

    # Desktop entry, deep-link handler and CLI on PATH.
    environment.systemPackages = [ cfg.package ];

    users.groups.firezone-client = {
      members = cfg.allowedUsers;
    };

    services.gnome.gnome-keyring.enable = lib.mkIf cfg.provisionKeyring (lib.mkDefault true);

    systemd.services.firezone-client-tunnel = {
      description = "Firezone Client Tunnel Service";
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
        FIREZONE_DNS_CONTROL = cfg.dnsControl;
        LOG_DIR = "/var/log/dev.firezone.client";
      }
      // cfg.extraEnvironment;

      serviceConfig = {
        Type = "notify";
        ExecStart = "${lib.getExe' cfg.package "firezone-client-tunnel"} run";
        # Root is required to control DNS.
        User = "root";
        Group = "firezone-client";

        TimeoutStartSec = "15s";
        TimeoutStopSec = "15s";
        Restart = "always";
        RestartSec = 7;

        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        # CAP_SYS_PTRACE is required to read /proc/<peer_pid>/exe for the
        # IPC peer allowlist check.
        CapabilityBoundingSet = [
          "CAP_CHOWN"
          "CAP_NET_ADMIN"
          "CAP_SYS_PTRACE"
        ];
        DeviceAllow = [ "/dev/net/tun" ];
        LogsDirectory = "dev.firezone.client";
        # Allow anyone to read log files.
        LogsDirectoryMode = "0755";
        RuntimeDirectory = "dev.firezone.client";
        StateDirectory = "dev.firezone.client";

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
          "@ipc"
          "@network-io"
          "@signal"
          "@system-service"
        ];
        UMask = "077";
      };
    };
  };
}
