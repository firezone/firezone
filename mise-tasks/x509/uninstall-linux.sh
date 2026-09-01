#!/usr/bin/env bash
#MISE description="Remove the test X.509 client certificate from the system SoftHSM PKCS#11 token"
set -euo pipefail

# One task per platform, so running the wrong one is a mistake worth naming rather than a
# confusing failure further down.
host_os="$(uname -s)"
if [ "$host_os" != "Linux" ]; then
    echo "error: this task removes a PKCS#11 token, but this is ${host_os}." >&2
    echo "'mise tasks' lists the task for this platform." >&2
    exit 1
fi

# Both of these are what `//:x509:install-linux` wrote, and the only two things it left behind.
SOFTHSM_CONF="/etc/softhsm/softhsm2.conf"
if [ ! -f "$SOFTHSM_CONF" ] && [ -f /etc/softhsm2.conf ]; then
    SOFTHSM_CONF="/etc/softhsm2.conf"
fi
PIN_PATH="/etc/firezone/pkcs11-pin"
TOKEN_LABEL="Firezone"

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

command -v softhsm2-util >/dev/null || {
    echo "error: softhsm2-util is required (Debian: apt install softhsm2; Fedora: dnf install softhsm)" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null; then
        echo "error: removing the system SoftHSM token and ${PIN_PATH} needs root, and sudo is" >&2
        echo "not installed; run this task as root instead" >&2
        exit 1
    fi

    # Elevating now means a refusal is its own error, rather than every check below reading
    # as "there was nothing there".
    if ! sudo true; then
        echo "error: sudo could not elevate, and removing the system SoftHSM token and" >&2
        echo "${PIN_PATH} needs root" >&2
        exit 1
    fi
fi

# SoftHSM prefers a per-user configuration over the system one, and `sudo` decides for itself
# whose home directory it looks in, so the system one is named outright.
system_softhsm=(env "SOFTHSM2_CONF=${SOFTHSM_CONF}")

echo "==> Deleting the ${TOKEN_LABEL} token..."
# A machine that never ran the install task has no token, which is not a failure. Anything
# else softhsm2-util reports is one, and it says so on stderr rather than in its exit status.
delete_status=0
delete_output="$(as_root "${system_softhsm[@]}" softhsm2-util --delete-token \
    --token "$TOKEN_LABEL" 2>&1)" || delete_status=$?

if [ "$delete_status" -eq 0 ]; then
    echo "    Deleted."
elif printf '%s' "$delete_output" | grep -qi "could not be found\|not found"; then
    echo "    No ${TOKEN_LABEL} token was in ${SOFTHSM_CONF}'s store."
else
    echo "error: could not delete the ${TOKEN_LABEL} token:" >&2
    printf '%s\n' "$delete_output" >&2
    exit 1
fi

echo "==> Removing ${PIN_PATH}..."
if as_root test -f "$PIN_PATH"; then
    as_root rm -f "$PIN_PATH"
    echo "    Removed."
else
    echo "    Not there."
fi

echo
echo "The Client has no identity to find now. A connected Tunnel service holds its PKCS#11"
echo "session until it restarts, so restart it to see the change."
