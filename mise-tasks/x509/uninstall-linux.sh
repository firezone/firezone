#!/usr/bin/env bash
#MISE description="Remove the test X.509 client certificate from the system SoftHSM PKCS#11 token"
set -euo pipefail

# One task per platform, so running the wrong one is a mistake worth naming rather than a
# confusing failure further down.
host_os="$(uname -s)"
if [ "$host_os" != "Linux" ]; then
    echo "error: this task removes from a PKCS#11 token, but this is ${host_os}." >&2
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

# The PIN `//:x509:install-linux` initialises the token with. Nothing here guards anything: the
# token holds a throwaway test key.
PKCS11_PIN="123456"

# A real deployment's certificates carry the same subject common name as ours, so only the CA a
# certificate chains to makes it this task's to delete, and nothing here falls back to the name:
# leaving one of ours behind costs a line of output, deleting an MDM's costs a machine its identity.
CA_CRT="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509/ca.crt"

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

softhsm_module() {
    local candidate

    if [ -n "${SOFTHSM2_MODULE:-}" ]; then
        printf '%s\n' "$SOFTHSM2_MODULE"
        return 0
    fi

    # Debian keeps the module under softhsm/, Fedora under pkcs11/ and without the 2.
    for candidate in \
        /usr/lib/softhsm/libsofthsm2.so \
        /usr/lib64/softhsm/libsofthsm2.so \
        /usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so \
        /usr/lib/aarch64-linux-gnu/softhsm/libsofthsm2.so \
        /usr/lib64/pkcs11/libsofthsm2.so \
        /usr/lib64/pkcs11/libsofthsm.so \
        /usr/lib/pkcs11/libsofthsm2.so \
        /usr/lib/pkcs11/libsofthsm.so \
        /usr/local/lib/softhsm/libsofthsm2.so; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

command -v softhsm2-util >/dev/null && command -v pkcs11-tool >/dev/null || {
    echo "error: softhsm2-util and pkcs11-tool are required (Debian: apt install softhsm2 opensc; Fedora: dnf install softhsm opensc)" >&2
    exit 1
}

# A certificate can be issued on one machine and only its PKCS#12 carried to another, so a
# machine can hold one of ours without ever holding the CA. Then the person running this is the
# only one who can tell the certificates apart, and there has to be a terminal to ask them at.
if [ ! -f "$CA_CRT" ] && [ ! -t 0 ]; then
    echo "error: no test CA in ${CA_CRT%/*}, so nothing here can tell a test certificate from any" >&2
    echo "other under that common name; run 'mise run //:x509:create-ca', or 'mise run //:x509:import-ca'" >&2
    echo "if another machine has the CA, or run this task from a terminal to choose by hand" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null; then
        echo "error: emptying the system SoftHSM token and removing ${PIN_PATH} needs root, and" >&2
        echo "sudo is not installed; run this task as root instead" >&2
        exit 1
    fi

    # Elevating now means a refusal is its own error, rather than every check below reading
    # as "there was nothing there".
    if ! sudo true; then
        echo "error: sudo could not elevate, and emptying the system SoftHSM token and removing" >&2
        echo "${PIN_PATH} needs root" >&2
        exit 1
    fi
fi

module="$(softhsm_module)" || {
    echo "error: no SoftHSM PKCS#11 module found; set SOFTHSM2_MODULE to its path" >&2
    exit 1
}

# SoftHSM prefers a per-user configuration over the system one, and `sudo` decides for itself
# whose home directory it looks in, so the system one is named outright.
system_softhsm=(env "SOFTHSM2_CONF=${SOFTHSM_CONF}")

work="$(mktemp -d)"
# shellcheck disable=SC2064 # `work` is expanded now on purpose; the trap outlives the variable.
trap "rm -rf '${work}'" EXIT

token() {
    as_root "${system_softhsm[@]}" pkcs11-tool --module "$module" --token-label "$TOKEN_LABEL" \
        --login --pin "$PKCS11_PIN" "$@"
}

# Enough of the certificate to recognise it by, since the answer is the only thing standing
# between it and deletion.
confirm_delete() {
    echo
    openssl x509 -in "${work}/cert.pem" -noout -subject -issuer -enddate -fingerprint -sha256 |
        sed 's/^/    /'
    read -r -p "    Delete ${1}? [y/N] " reply

    case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
    esac
}

# A machine that never ran the install task has no token, which is not a failure. Anything else
# pkcs11-tool reports is one, and it says so on stderr rather than in its exit status.
list_status=0
listing="$(token --list-objects --type cert 2>&1)" || list_status=$?

if [ "$list_status" -ne 0 ] && ! printf '%s' "$listing" | grep -qi "no slot"; then
    echo "error: could not read the ${TOKEN_LABEL} token:" >&2
    printf '%s\n' "$listing" >&2
    exit 1
fi

if [ "$list_status" -ne 0 ]; then
    listing=""
elif [ -f "$CA_CRT" ]; then
    echo "==> Removing certificates the test CA issued from the ${TOKEN_LABEL} token..."
else
    echo "==> No test CA in ${CA_CRT%/*}, so which of these are the test ones is yours to say."
fi

# A certificate and the key pair it belongs to share a CKA_ID, which is how both are named.
for id in $(printf '%s\n' "$listing" | awk '/^[[:blank:]]*ID:/ { print $2 }'); do
    token --read-object --type cert --id "$id" 2>/dev/null |
        openssl x509 -inform der -out "${work}/cert.pem"

    if [ -f "$CA_CRT" ]; then
        # An expired certificate is still ours and still wants deleting, hence `-no_check_time`.
        if ! openssl verify -CAfile "$CA_CRT" -no_check_time "${work}/cert.pem" >/dev/null 2>&1; then
            issuer="$(openssl x509 -in "${work}/cert.pem" -noout -issuer | sed 's/^issuer=//')"
            echo "    Kept ${id}, which the test CA did not issue: ${issuer}"
            continue
        fi
    elif ! confirm_delete "$id"; then
        echo "    Kept ${id}."
        continue
    fi

    token --delete-object --type cert --id "$id" >/dev/null
    # A certificate can sit on a token on its own, so its key pair is not always there.
    token --delete-object --type privkey --id "$id" >/dev/null 2>&1 || true
    token --delete-object --type pubkey --id "$id" >/dev/null 2>&1 || true
    echo "    Removed ${id} and its key pair."
done

# Whatever is left on the token needs the token and the PIN that opens it, so the two go only
# once nothing is. A token that is not there lists nothing and reads the same as an empty one.
remaining="$(token --list-objects 2>/dev/null || true)"

if [ -n "$remaining" ]; then
    echo
    echo "The ${TOKEN_LABEL} token and ${PIN_PATH} stay, because what is still on the token needs"
    echo "both. A connected Tunnel service holds its PKCS#11 session until it restarts, so restart it"
    echo "to see the change."

    exit 0
fi

echo "==> Deleting the ${TOKEN_LABEL} token..."
delete_status=0
delete_output="$(as_root "${system_softhsm[@]}" softhsm2-util --delete-token \
    --token "$TOKEN_LABEL" 2>&1)" || delete_status=$?

if [ "$delete_status" -eq 0 ]; then
    echo "    Deleted."
elif [ "$list_status" -ne 0 ]; then
    # The listing found no token, so softhsm2-util had none to delete either, whatever it says.
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
