#!/usr/bin/env bash
#MISE description="Import the test X.509 client certificate into the system SoftHSM PKCS#11 token"
#USAGE flag "--alias <alias>" help="Name `//:x509:gen-certificate` stored the key under [default: firezone-client]"
#USAGE flag "--password <password>" help="PKCS#12 export password [default: firezone]"
set -euo pipefail

CERT_ALIAS="${usage_alias:-firezone-client}"
P12_PASSWORD="${usage_password:-firezone}"
P12_PATH="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509/${CERT_ALIAS}.p12"

# One task per platform, so running the wrong one is a mistake worth naming rather than a
# confusing failure further down.
host_os="$(uname -s)"
if [ "$host_os" != "Linux" ]; then
    echo "error: this task installs into a PKCS#11 token, but this is ${host_os}." >&2
    echo "'mise tasks' lists the task for this platform." >&2
    exit 1
fi

if [ ! -f "$P12_PATH" ]; then
    echo "error: ${P12_PATH} does not exist; run 'mise run //:x509:gen-certificate' first" >&2
    exit 1
fi

# The private key passes through a file on its way into the token, and the token holds it
# afterwards, so neither is left for anyone but root to read.
umask 077

# The Tunnel service runs as root under `ProtectHome=true`, which leaves it nothing below /home
# to read, so both the token and its PIN belong in system-wide locations.
# Distributions compile different config paths into the library: Debian /etc/softhsm/, Fedora
# /etc directly. The Client reads the token through that compiled-in default, so the import has
# to land in whichever file this machine's build actually reads.
SOFTHSM_CONF="/etc/softhsm/softhsm2.conf"
if [ ! -f "$SOFTHSM_CONF" ] && [ -f /etc/softhsm2.conf ]; then
    SOFTHSM_CONF="/etc/softhsm2.conf"
fi
PIN_PATH="/etc/firezone/pkcs11-pin"

# `//:x509:gen-certificate` issues the certificate under this common name, and the Client goes
# looking for that name rather than being told where the certificate is.
SUBJECT_CN="dev.firezone.device-trust"

# The Client finds the private key by the CKA_ID it shares with the certificate, so both objects
# are written with the same one. The labels are for people reading `pkcs11-tool --list-objects`.
TOKEN_LABEL="Firezone"
OBJECT_LABEL="device-trust"
OBJECT_ID="01"

# SoftHSM refuses a PIN shorter than four characters. Nothing here guards anything: the token
# holds a throwaway test key.
PKCS11_PIN="123456"

# Writing the token and the PIN needs root, and the rest of the task does not, so the two steps
# that need it ask for it rather than the whole task re-executing itself under `sudo`.
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

# Only the paths the Client itself searches, in the same order. p11-kit installs the proxy into
# the library directory itself (/usr/lib64 on Fedora, the multiarch directory on Debian); only
# registered driver modules live under pkcs11/. /usr/lib64 is probed before /usr/lib because a
# 32-bit p11-kit package leaves a proxy of the wrong architecture in /usr/lib.
p11_kit_proxy() {
    local candidate

    for candidate in \
        /usr/lib64/p11-kit-proxy.so \
        /usr/lib/*/p11-kit-proxy.so \
        /usr/lib/p11-kit-proxy.so \
        /usr/lib/*/pkcs11/p11-kit-proxy.so \
        /usr/lib/pkcs11/p11-kit-proxy.so \
        /usr/lib64/pkcs11/p11-kit-proxy.so; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# The proxy offers up whatever these two directories register, and nothing else.
p11_kit_registers_softhsm() {
    grep -rqsE '^[[:blank:]]*module:.*libsofthsm2?\.so' \
        /usr/share/p11-kit/modules /etc/pkcs11/modules
}

# Debian ships both the configuration and the directory it names, but where they sit is a
# distribution's choice, so the directory is read out of the configuration rather than assumed.
system_token_dir() {
    as_root awk '
        /^[[:blank:]]*directories\.tokendir[[:blank:]]*=/ {
            sub(/^[^=]*=[[:blank:]]*/, "")
            sub(/[[:blank:]]+$/, "")
            print
        }
    ' "$SOFTHSM_CONF" | tail -n 1
}

command -v softhsm2-util >/dev/null && command -v pkcs11-tool >/dev/null || {
    echo "error: softhsm2-util and pkcs11-tool are required (Debian: apt install softhsm2 opensc; Fedora: dnf install softhsm opensc)" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null; then
        echo "error: writing the system SoftHSM token store and ${PIN_PATH} needs root, and sudo" >&2
        echo "is not installed; run this task as root instead" >&2
        exit 1
    fi

    # Elevating now means the password prompt, and a refusal, come before anything is half-written.
    if ! sudo true; then
        echo "error: sudo could not elevate, and writing the system SoftHSM token store and" >&2
        echo "${PIN_PATH} needs root" >&2
        exit 1
    fi
fi

module="$(softhsm_module)" || {
    echo "error: no SoftHSM PKCS#11 module found; set SOFTHSM2_MODULE to its path" >&2
    exit 1
}

# This configuration is the one the Client's SoftHSM module reads, so the token it describes is
# the only token the Client can find. On Debian it belongs to the `softhsm` group, hence root.
as_root test -f "$SOFTHSM_CONF" || {
    echo "error: no system SoftHSM configuration at ${SOFTHSM_CONF} (Debian: apt install softhsm2; Fedora: dnf install softhsm)" >&2
    exit 1
}

token_dir="$(system_token_dir)"
# Debian writes the directory with a trailing slash, which only makes the messages below uglier.
token_dir="${token_dir%/}"

if [ -z "$token_dir" ]; then
    echo "error: ${SOFTHSM_CONF} sets no directories.tokendir" >&2
    exit 1
fi

as_root test -d "$token_dir" || {
    echo "error: ${SOFTHSM_CONF} names ${token_dir}, which does not exist" >&2
    exit 1
}

# SoftHSM prefers a per-user configuration over the system one, and `sudo` decides for itself
# whose home directory it looks in, so every step below names the system one outright.
system_softhsm=(env "SOFTHSM2_CONF=${SOFTHSM_CONF}")

work="$(mktemp -d)"
# shellcheck disable=SC2064 # `work` is expanded now on purpose; the trap outlives the variable.
trap "rm -rf '${work}'" EXIT

echo "==> Initialising the ${TOKEN_LABEL} token in ${token_dir}..."
# Recreated from scratch so that re-running leaves exactly one identity on the token.
as_root "${system_softhsm[@]}" softhsm2-util --delete-token --token "$TOKEN_LABEL" >/dev/null 2>&1 || true
as_root "${system_softhsm[@]}" softhsm2-util --init-token --free --label "$TOKEN_LABEL" \
    --so-pin "$PKCS11_PIN" --pin "$PKCS11_PIN" >/dev/null

# SoftHSM imports keys from PKCS#8 only, and OpenSSL writes bag attributes ahead of the key
# when it unpacks a PKCS#12, so the key goes through `pkcs8` to come out on its own.
openssl pkcs12 -in "$P12_PATH" -passin "pass:${P12_PASSWORD}" -nocerts -nodes |
    openssl pkcs8 -topk8 -nocrypt -out "${work}/key.pem"
openssl pkcs12 -in "$P12_PATH" -passin "pass:${P12_PASSWORD}" -clcerts -nokeys |
    openssl x509 -outform der -out "${work}/leaf.der"

echo "==> Importing the key and certificate..."
as_root "${system_softhsm[@]}" softhsm2-util --import "${work}/key.pem" --token "$TOKEN_LABEL" \
    --label "$OBJECT_LABEL" --id "$OBJECT_ID" --pin "$PKCS11_PIN" >/dev/null
# softhsm2-util imports key pairs only, so the certificate object is written separately. There is
# no p11-kit route to either step: the proxy is how the Client reads the token, not how it is made.
as_root "${system_softhsm[@]}" pkcs11-tool --module "$module" --token-label "$TOKEN_LABEL" \
    --login --pin "$PKCS11_PIN" --write-object "${work}/leaf.der" --type cert \
    --label "$OBJECT_LABEL" --id "$OBJECT_ID" >/dev/null

echo "==> Writing the PIN to ${PIN_PATH}..."
# The Client refuses a PIN file that is not root's alone, so the file arrives with its mode
# rather than being fixed up afterwards.
printf '%s\n' "$PKCS11_PIN" >"${work}/pin"
as_root install -d -m 0755 -o root -g root "${PIN_PATH%/*}"
as_root install -m 0400 -o root -g root "${work}/pin" "$PIN_PATH"

if ! p11_kit_registers_softhsm; then
    echo "warning: no p11-kit module file registers SoftHSM, so the proxy will not offer the" >&2
    echo "token to the Client (Debian: apt install softhsm2; Fedora: dnf install softhsm)" >&2
fi

# Listing through the proxy is what proves the Client can find the token, because the proxy is
# the only module it loads.
list_module="$(p11_kit_proxy)" || {
    echo "warning: no p11-kit-proxy.so found, so the listing below goes through SoftHSM directly" >&2
    echo "rather than through the module the Client loads (Debian: apt install p11-kit-modules; Fedora: dnf install p11-kit)" >&2
    list_module="$module"
}

echo
echo "==> On the token, through ${list_module}:"
as_root "${system_softhsm[@]}" pkcs11-tool --module "$list_module" --token-label "$TOKEN_LABEL" \
    --login --pin "$PKCS11_PIN" --list-objects | sed 's/^/    /'

echo
echo "The token is in the system store and its PIN is at ${PIN_PATH}, which is all the Client"
echo "needs: it loads p11-kit's proxy module and takes the certificate whose subject common name is"
echo "${SUBJECT_CN}. There is nothing to configure, packaged Tunnel service included."
