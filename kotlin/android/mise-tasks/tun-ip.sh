#!/usr/bin/env bash
#MISE description="Print the Firezone tunnel IPv4/IPv6 of the connected Android device/emulator"
set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
export ANDROID_HOME
export PATH="$ANDROID_HOME/platform-tools:$PATH"

if ! command -v adb >/dev/null 2>&1; then
    echo "adb not found in PATH. Run 'mise run setup' first." >&2
    exit 1
fi

# Require exactly one device, unless ANDROID_SERIAL is set (then adb targets that one).
if [ -z "${ANDROID_SERIAL:-}" ]; then
    device_count=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
    case "$device_count" in
    0)
        echo "No Android device or emulator online. Run 'mise run install-emulator' or plug a device in." >&2
        exit 1
        ;;
    1) ;;
    *)
        echo "Multiple devices detected. Set ANDROID_SERIAL to pick one:" >&2
        adb devices >&2
        exit 1
        ;;
    esac
fi

# tun0 is the interface Firezone's VpnService installs. Its addresses sit in the
# tunnel ranges (IPV4_TUNNEL 100.64.0.0/11, IPV6_TUNNEL fd00:2021:1111::/107).
# awk/cut run host-side because Android's toybox ships no awk; -o keeps each
# address on one line, and the IPv6 filter drops the link-local (fe80::) address.
tunnel_ipv4=$(adb shell ip -4 -o addr show tun0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
tunnel_ipv6=$(adb shell ip -6 -o addr show tun0 2>/dev/null | awk '$4 !~ /^fe80/ {print $4}' | cut -d/ -f1 | head -1)

if [ -z "$tunnel_ipv4" ] && [ -z "$tunnel_ipv6" ]; then
    echo "No tun0 interface found - is the Firezone tunnel connected?" >&2
    exit 1
fi

echo "IPv4: ${tunnel_ipv4:-<none>}"
echo "IPv6: ${tunnel_ipv6:-<none>}"
