#!/usr/bin/env bash
#MISE description="Import the test X.509 client certificate into the login keychain"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_os 'Darwin' 'a macOS keychain'
require_p12

FIREZONE_APP="${FIREZONE_APP:-/Applications/Firezone.app}"

# `security login-keychain` prints the path quoted and indented.
keychain="$(security login-keychain | sed -e 's/^[[:blank:]]*//' -e 's/"//g')"

import_args=(import "$P12_PATH" -k "$keychain" -f pkcs12 -P "$P12_PASSWORD")

# With no application on its ACL, macOS asks for confirmation before anything signs with the key.
# The Network Extension has no UI and could never answer that prompt, so the app bundle it ships in
# goes on the ACL as the key is imported.
if [ -d "$FIREZONE_APP" ]; then
    import_args+=(-T "$FIREZONE_APP")
else
    echo "note: ${FIREZONE_APP} is not installed, so no application is pre-authorised for the key"
fi

echo "==> Importing ${P12_PATH} into ${keychain}..."
security "${import_args[@]}" || {
    echo
    echo "If the import failed because the identity is already there, delete the existing"
    echo "'${CERT_SUBJECT_CN}' identity in Keychain Access and run this again."
    exit 1
}

echo
echo "==> Identities in the login keychain:"
security find-identity -v "$keychain" | grep -F "$CERT_SUBJECT_CN" ||
    echo "    none matching ${CERT_SUBJECT_CN}"

echo
echo "The Client will not use this identity yet. It signs with the identity its VPN configuration"
echo "points at (NEVPNProtocol.identityReference), and only a configuration profile can set that:"
echo "the profile needs a com.apple.security.pkcs12 payload carrying this certificate and a VPN"
echo "payload whose PayloadCertificateUUID is that payload's PayloadUUID. On macOS the certificate"
echo "payload also needs AllowAllAppsAccess set, or the Network Extension cannot sign with the key."
echo
echo "What you do get is an identity that Keychain Access and 'security find-identity' can see,"
echo "which is enough to check that the certificate and its key arrived intact."
echo
echo "iOS has no equivalent at all: a profile is the only way in, and the Simulator's"
echo "'simctl keychain' takes root certificates only, never an identity."
