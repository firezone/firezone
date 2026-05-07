#!/usr/bin/env bash

set -euo pipefail

hostname=$(hostname)
FIREZONE_NAME=${FIREZONE_NAME:-$hostname}
FIREZONE_ID=${FIREZONE_ID:-}
FIREZONE_TOKEN=${FIREZONE_TOKEN:-}
FIREZONE_API_URL=${FIREZONE_API_URL:-wss://api.firezone.dev}
RUST_LOG=${RUST_LOG:-info}

# mark:current-gateway-version
GATEWAY_VERSION="1.5.2"
# mark:gateway-x86_64-sha256
GATEWAY_X86_64_SHA256="1f1d7e575a01e592d64aa93ea9c6025ee33e7b77dc9c507c18695600c1c41cc0"
# mark:gateway-aarch64-sha256
GATEWAY_AARCH64_SHA256="0772158376371a16d773ecfc1e5cffc6c7f0b92418df6623d6aed61945dda82b"
# mark:gateway-armv7-sha256
GATEWAY_ARMV7_SHA256="57db065b1ac89e55c2d3be436164f1674130136419e242736ad9ddbf0b2b1fb1"

# Optional environment variables to configure logging and tracing
FIREZONE_OTLP_GRPC_ENDPOINT=${OTLP_GRPC_ENDPOINT:-}
FIREZONE_GOOGLE_CLOUD_PROJECT_ID=${GOOGLE_CLOUD_PROJECT_ID:-}
FIREZONE_LOG_FORMAT=${FIREZONE_LOG_FORMAT:-}

SERVICE_FILE=${SERVICE_FILE:-/etc/systemd/system/firezone-gateway.service}
TOKEN_FILE=${TOKEN_FILE:-/etc/firezone/gateway-token}

legacy_unit_environment() {
    local name=$1

    [ -r "$SERVICE_FILE" ] || return 0

    sed -n "s/^Environment=\"$name=\(.*\)\"$/\1/p" "$SERVICE_FILE" | tail -n 1
}

if [ -z "$FIREZONE_TOKEN" ]; then
    FIREZONE_TOKEN=$(legacy_unit_environment FIREZONE_TOKEN)
fi

if [ -z "$FIREZONE_ID" ]; then
    FIREZONE_ID=$(legacy_unit_environment FIREZONE_ID)
fi

if [ -z "$FIREZONE_ID" ]; then
    echo "FIREZONE_ID is required"
    exit 1
fi

if [ -z "$FIREZONE_TOKEN" ] && ! sudo test -s "$TOKEN_FILE"; then
    echo "FIREZONE_TOKEN is required"
    exit 1
fi

if ! systemd_version=$(systemctl --version | awk 'NR == 1 { print $2 }'); then
    echo "systemctl is required"
    exit 1
fi

case "$systemd_version" in
"" | *[!0-9]*)
    echo "Could not determine systemd version"
    exit 1
    ;;
esac

if [ "$systemd_version" -lt 247 ]; then
    echo "systemd 247 or newer is required to pass FIREZONE_TOKEN as a credential"
    exit 1
fi

# Setup user and group
sudo groupadd -f firezone
id -u firezone >/dev/null 2>&1 || sudo useradd -r -g firezone -s /sbin/nologin firezone

sudo install -d -m 0755 -o root -g root /etc/firezone

if [ -n "$FIREZONE_TOKEN" ]; then
    printf '%s\n' "$FIREZONE_TOKEN" | sudo sh -c '
        set -e
        token_file=$1
        token_tmp=$(mktemp "${token_file}.XXXXXX")
        trap '\''rm -f "$token_tmp"'\'' EXIT
        cat > "$token_tmp"
        chown root:root "$token_tmp"
        chmod 0400 "$token_tmp"
        mv "$token_tmp" "$token_file"
        trap - EXIT
    ' sh "$TOKEN_FILE"
fi

# Create systemd unit file
cat <<EOF | sudo tee "$SERVICE_FILE"
[Unit]
Description=Firezone Gateway
After=network.target
Documentation=https://www.firezone.dev/kb

[Service]

# DO NOT EDIT ANY OF THE BELOW BY HAND. USE "systemctl edit firezone-gateway" INSTEAD TO CUSTOMIZE.

Type=simple
User=firezone
Group=firezone
PermissionsStartOnly=true
SyslogIdentifier=firezone-gateway

LoadCredential=FIREZONE_TOKEN:$TOKEN_FILE

Environment="FIREZONE_NAME=$FIREZONE_NAME"
Environment="FIREZONE_ID=$FIREZONE_ID"
Environment="FIREZONE_API_URL=$FIREZONE_API_URL"
Environment="RUST_LOG=$RUST_LOG"
Environment="RUST_LOG_STYLE=never"
Environment="LOG_FORMAT=$FIREZONE_LOG_FORMAT"
Environment="GOOGLE_CLOUD_PROJECT_ID=$FIREZONE_GOOGLE_CLOUD_PROJECT_ID"
Environment="OTLP_GRPC_ENDPOINT=$FIREZONE_OTLP_GRPC_ENDPOINT"

# ExecStartPre script to download the gateway binary
ExecStartPre=/usr/local/bin/firezone-gateway-init

# ExecStart script
ExecStart=/opt/firezone/bin/firezone-gateway

# Restart on failure
TimeoutStartSec=15s
TimeoutStopSec=15s
Restart=always
RestartSec=7

#####################
# HARDENING OPTIONS #
#####################

# Give the service its own private /tmp directory.
PrivateTmp=true

# Mount the system directories read-only (except those explicitly allowed).
ProtectSystem=full

# Make users' home directories read-only.
ProtectHome=read-only

# Disallow gaining new privileges (e.g. via execve() of setuid binaries).
NoNewPrivileges=true

# Disallow the creation of new namespaces.
RestrictNamespaces=yes

# Prevent memory from being both writable and executable.
MemoryDenyWriteExecute=true

# Prevent the service from calling personality(2) to change process execution domain.
LockPersonality=true

# Restrict the set of allowed address families.
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK

# Allow the process to have CAP_NET_ADMIN (needed for network administration)
# while restricting it to only that capability.
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN

# Make some sensitive paths inaccessible.
InaccessiblePaths=/root /home

# Set resource limits
LimitNOFILE=4096
LimitNPROC=512
LimitCORE=0

# Set a sane system call filter
SystemCallFilter=@system-service

[Install]
WantedBy=multi-user.target
EOF

# Create ExecStartPre script
cat <<EOF | sudo tee /usr/local/bin/firezone-gateway-init
#!/bin/sh

set -ue

# Define the target directory and binary path
TARGET_DIR="/opt/firezone/bin"
BINARY_PATH="\$TARGET_DIR/firezone-gateway"
ARTIFACT_BASE_URL="https://www.firezone.dev/dl/firezone-gateway"
GATEWAY_VERSION="${GATEWAY_VERSION}"

case "\$(uname -m)" in
  x86_64)
    arch="x86_64"
    expected_sha256="${GATEWAY_X86_64_SHA256}"
    ;;
  aarch64 | arm64)
    arch="aarch64"
    expected_sha256="${GATEWAY_AARCH64_SHA256}"
    ;;
  armv7 | armv7l)
    arch="armv7"
    expected_sha256="${GATEWAY_ARMV7_SHA256}"
    ;;
  *)
    echo "Unsupported architecture: \$(uname -m)"
    exit 1
    ;;
esac

download_url="\$ARTIFACT_BASE_URL/\$GATEWAY_VERSION/\$arch"

sha256_for() {
  sha256sum "\$1" | awk '{ print \$1 }'
}

# Create the directory if it doesn’t exist
if [ ! -d "\$TARGET_DIR" ]; then
  mkdir -p "\$TARGET_DIR"
  chown firezone:firezone "\$TARGET_DIR"
  chmod 0755 "\$TARGET_DIR"
fi


# Download the configured gateway version if it doesn't already exist
needs_download=0
if [ -e "\$BINARY_PATH" ]; then
  actual_sha256=\$(sha256_for "\$BINARY_PATH")

  if [ "\$actual_sha256" = "\$expected_sha256" ]; then
    echo "\$BINARY_PATH found and checksum verified. Skipping download."
  else
    echo "\$BINARY_PATH found, but checksum does not match Firezone Gateway \$GATEWAY_VERSION for \$arch."
    needs_download=1
  fi
else
  echo "\$BINARY_PATH not found."
  needs_download=1
fi

if [ "\$needs_download" -eq 1 ]; then
  echo "Downloading Firezone Gateway \$GATEWAY_VERSION from \$download_url..."

  # See https://www.firezone.dev/changelog for available binaries
  rm -f "\$BINARY_PATH.download"
  curl -fsSL "\$download_url" -o "\$BINARY_PATH.download"

  actual_sha256=\$(sha256_for "\$BINARY_PATH.download")
  if [ "\$actual_sha256" != "\$expected_sha256" ]; then
    echo "\$BINARY_PATH.download failed checksum verification!"
    echo "Expected: \$expected_sha256"
    echo "Actual:   \$actual_sha256"
    rm -f "\$BINARY_PATH.download"
    exit 1
  fi

  if file "\$BINARY_PATH.download" | grep -q "ELF"; then
    mv "\$BINARY_PATH.download" "\$BINARY_PATH"
  else
    echo "\$BINARY_PATH.download is not an executable!"
    echo "Ensure '\$download_url' is accessible from this machine,"
    echo "or download binary manually and install to \$BINARY_PATH"
    rm -f "\$BINARY_PATH.download"
    exit 1
  fi
fi

# Set proper permissions on each start
chmod 0755 "\$BINARY_PATH"
chown firezone:firezone "\$BINARY_PATH"

# Enable masquerading for Firezone tunnel traffic
iptables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || iptables -I FORWARD 1 -i tun-firezone -j ACCEPT
iptables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || iptables -I FORWARD 1 -o tun-firezone -j ACCEPT
iptables -t nat -C POSTROUTING -s 100.64.0.0/11 -o e+ -j MASQUERADE > /dev/null 2>&1 || iptables -t nat -A POSTROUTING -s 100.64.0.0/11 -o e+ -j MASQUERADE
iptables -t nat -C POSTROUTING -s 100.64.0.0/11 -o w+ -j MASQUERADE > /dev/null 2>&1 || iptables -t nat -A POSTROUTING -s 100.64.0.0/11 -o w+ -j MASQUERADE
ip6tables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || ip6tables -I FORWARD 1 -i tun-firezone -j ACCEPT
ip6tables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || ip6tables -I FORWARD 1 -o tun-firezone -j ACCEPT
ip6tables -t nat -C POSTROUTING -s fd00:2021:1111::/107 -o e+ -j MASQUERADE > /dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -s fd00:2021:1111::/107 -o e+ -j MASQUERADE
ip6tables -t nat -C POSTROUTING -s fd00:2021:1111::/107 -o w+ -j MASQUERADE > /dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -s fd00:2021:1111::/107 -o w+ -j MASQUERADE

# Enable packet forwarding for IPv4 and IPv6
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.src_valid_mark=1
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.default.forwarding=1
EOF

# Make ExecStartPre script executable
sudo chmod +x /usr/local/bin/firezone-gateway-init

# Reload systemd
sudo systemctl daemon-reload

# Enable the service to start on boot
sudo systemctl enable firezone-gateway

# Start the service
sudo systemctl start firezone-gateway

echo "Firezone Gateway installed successfully!"
echo "Run 'sudo systemctl status firezone-gateway' to check the status."
