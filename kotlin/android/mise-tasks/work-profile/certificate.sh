#!/usr/bin/env bash
#MISE description="Generate a Firezone-style client certificate and stage it for the work profile's KeyChain"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

# The claims the client reads out of a managed certificate are URI subject alternative names of the
# form `firezone://<attribute>/<value>`; see `rust/libs/x509-claims/src/lib.rs`. These defaults make
# the certificate screen show real values instead of blanks.
CERT_ALIAS="${CERT_ALIAS:-firezone-client}"
ACTOR_EMAIL="${ACTOR_EMAIL:-alice@example.com}"
ACCOUNT_ID="${ACCOUNT_ID:-d7a2f1f0-5b6c-4d3e-9a1b-2c3d4e5f6a7b}"
MDM_DEVICE_ID="${MDM_DEVICE_ID:-5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3}"
DEVICE_SERIAL="${DEVICE_SERIAL:-EMU8CE1F0A2}"
P12_PASSWORD="${P12_PASSWORD:-firezone}"
OUT_DIR="${OUT_DIR:-${TMPDIR:-/tmp}/firezone-work-profile}"

require_adb

p12="${OUT_DIR}/${CERT_ALIAS}.p12"

mkdir -p "$OUT_DIR"

# Everything goes through config files rather than `-addext`, so this also runs against the
# LibreSSL that macOS ships as /usr/bin/openssl.
cat >"${OUT_DIR}/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ca_ext

[dn]
O = Firezone
CN = Firezone Work Profile Test CA

[ca_ext]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat >"${OUT_DIR}/client.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no

[dn]
O = Firezone
CN = ${ACTOR_EMAIL}

[client_ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
subjectAltName = @san

[san]
URI.1 = firezone://email/${ACTOR_EMAIL}
URI.2 = firezone://account-id/${ACCOUNT_ID}
URI.3 = firezone://intune-id/${MDM_DEVICE_ID}
URI.4 = firezone://serial/${DEVICE_SERIAL}
EOF

echo "==> Generating a test issuing CA in ${OUT_DIR}..."
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "${OUT_DIR}/ca.cnf" \
    -keyout "${OUT_DIR}/ca.key" \
    -out "${OUT_DIR}/ca.crt" 2>/dev/null

echo "==> Issuing a client certificate for ${ACTOR_EMAIL}..."
openssl req -new -newkey rsa:2048 -nodes \
    -config "${OUT_DIR}/client.cnf" \
    -keyout "${OUT_DIR}/client.key" \
    -out "${OUT_DIR}/client.csr" 2>/dev/null

openssl x509 -req -sha256 -days 825 \
    -in "${OUT_DIR}/client.csr" \
    -CA "${OUT_DIR}/ca.crt" \
    -CAkey "${OUT_DIR}/ca.key" \
    -CAcreateserial \
    -extfile "${OUT_DIR}/client.cnf" \
    -extensions client_ext \
    -out "${OUT_DIR}/client.crt" 2>/dev/null

echo "==> Packing ${p12}..."
# Android's KeyChain importer reads PKCS#12 through BouncyCastle, which does not take OpenSSL 3's
# default AES-256/PBKDF2 encryption. SHA1/3DES is what it expects, and unlike `-legacy` it needs no
# extra provider on the host. Older OpenSSL and LibreSSL already default to that and may not know
# the flags, hence the retry.
pkcs12_args=(
    -export
    -inkey "${OUT_DIR}/client.key"
    -in "${OUT_DIR}/client.crt"
    -certfile "${OUT_DIR}/ca.crt"
    -name "$CERT_ALIAS"
    -passout "pass:${P12_PASSWORD}"
    -out "$p12"
)

if ! openssl pkcs12 "${pkcs12_args[@]}" -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null; then
    openssl pkcs12 "${pkcs12_args[@]}"
fi

echo "==> Subject alternative names:"
openssl x509 -in "${OUT_DIR}/client.crt" -noout -text |
    awk '/Subject Alternative Name/ {getline; print}' |
    sed 's/^ */    /'

user_id="$(require_work_profile_user)" || exit 1

# The DPC's file picker only sees the work profile's own storage, and `adb push` writes user 0's.
# The AOSP images are userdebug, so `adb root` can put the file where the profile can reach it.
staged=0
echo "==> Staging the certificate in the work profile's Downloads..."
if adb root >/dev/null 2>&1 && adb wait-for-device; then
    adb push "$p12" "/data/local/tmp/${CERT_ALIAS}.p12" >/dev/null
    if adb shell mkdir -p "/data/media/${user_id}/Download" &&
        adb shell cp "/data/local/tmp/${CERT_ALIAS}.p12" "/data/media/${user_id}/Download/${CERT_ALIAS}.p12" &&
        adb shell restorecon -R "/data/media/${user_id}/Download"; then
        staged=1
    fi
fi

echo
echo "The rest cannot be scripted: installing a key pair into the KeyChain is a profile-owner API"
echo "and no adb command exposes it. Do this by hand in the emulator:"
echo
if [ "$staged" = "1" ]; then
    echo "  The file is already at Download/${CERT_ALIAS}.p12 inside the work profile."
else
    echo "  Staging into the work profile's storage failed. Copy ${p12} onto the device yourself,"
    echo "  e.g. by dragging it onto the emulator window, before starting."
fi
echo
echo "  1. Open TestDPC in the work profile (the badged icon in the launcher)."
echo "  2. Pick 'Manage certificates' and then 'Install KeyPair'."
echo "  3. Choose Download/${CERT_ALIAS}.p12 and enter the password: ${P12_PASSWORD}"
echo "  4. When asked for an alias, type exactly: ${CERT_ALIAS}"
echo "  5. Do NOT use 'Grant KeyPair to app' afterwards. Withholding that grant is the whole"
echo "     point: it is the state a personally-owned device is in, and it is what sends the app"
echo "     to the certificate screen."
echo
echo "  Alternative without the DPC, same end state: in the work profile's Settings, go to"
echo "  Security & privacy, Encryption & credentials, 'Install a certificate', 'VPN & app user"
echo "  certificate', pick the file and name it ${CERT_ALIAS}."
echo
echo "==> Next: mise run //kotlin/android:work-profile:managed-config"
