#!/usr/bin/env bash
#MISE description="Issue a throwaway X.509 client certificate and pack it as a PKCS#12"
set -euo pipefail

# Everything written below is private key material, so nobody else on the machine may read it.
umask 077

# The Clients only consider a certificate whose subject common name is this one, and read
# everything else about it out of URI subject alternative names of the form
# `firezone://<attribute>/<value>`.
CERT_SUBJECT_CN="${CERT_SUBJECT_CN:-dev.firezone.device-trust}"

# `user` carries the actor email and account id, which is what lets a client sign in as a portal
# identity. `device` leaves both out, so the certificate can only ever attest the device.
CERT_KIND="${CERT_KIND:-user}"

CERT_ALIAS="${CERT_ALIAS:-firezone-client}"
ACTOR_EMAIL="${ACTOR_EMAIL:-alice@example.com}"
ACCOUNT_ID="${ACCOUNT_ID:-d7a2f1f0-5b6c-4d3e-9a1b-2c3d4e5f6a7b}"
MDM_DEVICE_ID="${MDM_DEVICE_ID:-5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3}"
DEVICE_SERIAL="${DEVICE_SERIAL:-FZTESTSERIAL1}"
P12_PASSWORD="${P12_PASSWORD:-firezone}"

# Set to 1 to throw the CA away and start over. Every certificate issued by the previous one stops
# chaining to the trust anchor the portal has registered.
REGENERATE_CA="${REGENERATE_CA:-0}"

OUT_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509"

case "$CERT_KIND" in
user | device) ;;
*)
    echo "error: CERT_KIND must be 'user' or 'device', got '${CERT_KIND}'" >&2
    exit 1
    ;;
esac

command -v openssl >/dev/null || {
    echo "error: openssl is not installed" >&2
    exit 1
}

ca_crt="${OUT_DIR}/ca.crt"
ca_key="${OUT_DIR}/ca.key"
client_crt="${OUT_DIR}/${CERT_ALIAS}.crt"
client_key="${OUT_DIR}/${CERT_ALIAS}.key"
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
CN = Firezone Test CA

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
CN = ${CERT_SUBJECT_CN}

[client_ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
subjectAltName = @san

[san]
EOF

if [ "$CERT_KIND" = "user" ]; then
    cat >>"${OUT_DIR}/client.cnf" <<EOF
URI.1 = firezone://email/${ACTOR_EMAIL}
URI.2 = firezone://account-id/${ACCOUNT_ID}
URI.3 = firezone://intune-id/${MDM_DEVICE_ID}
URI.4 = firezone://serial/${DEVICE_SERIAL}
EOF
else
    cat >>"${OUT_DIR}/client.cnf" <<EOF
URI.1 = firezone://intune-id/${MDM_DEVICE_ID}
URI.2 = firezone://serial/${DEVICE_SERIAL}
EOF
fi

# The CA outlives a single run: it is the trust anchor registered in the portal, and issuing a
# second certificate must not invalidate the one that is already registered there.
if [ "$REGENERATE_CA" = "1" ] || [ ! -f "$ca_crt" ] || [ ! -f "$ca_key" ]; then
    echo "==> Generating a test CA in ${OUT_DIR}..."
    rm -f "${OUT_DIR}/ca.srl"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -config "${OUT_DIR}/ca.cnf" \
        -keyout "$ca_key" \
        -out "$ca_crt" 2>/dev/null
else
    echo "==> Reusing the test CA in ${OUT_DIR}"
fi

echo "==> Issuing a ${CERT_KIND} certificate as ${CERT_SUBJECT_CN}..."
openssl req -new -newkey rsa:2048 -nodes \
    -config "${OUT_DIR}/client.cnf" \
    -keyout "$client_key" \
    -out "${OUT_DIR}/client.csr" 2>/dev/null

openssl x509 -req -sha256 -days 825 \
    -in "${OUT_DIR}/client.csr" \
    -CA "$ca_crt" \
    -CAkey "$ca_key" \
    -CAcreateserial \
    -extfile "${OUT_DIR}/client.cnf" \
    -extensions client_ext \
    -out "$client_crt" 2>/dev/null

echo "==> Packing ${p12}..."
# SHA1/3DES is the one PKCS#12 profile every keystore we install into accepts: Windows documents
# TripleDES-SHA1 and AES256-SHA256 as the only two it imports, Apple's Security framework rejects
# OpenSSL 3's default SHA-256 MAC, and Android's BouncyCastle importer wants SHA1/3DES as well.
# Older OpenSSL and LibreSSL already default to that and may not know the flags, hence the retry.
pkcs12_args=(
    -export
    -inkey "$client_key"
    -in "$client_crt"
    -certfile "$ca_crt"
    -name "$CERT_ALIAS"
    -passout "pass:${P12_PASSWORD}"
    -out "$p12"
)

if ! openssl pkcs12 "${pkcs12_args[@]}" -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null; then
    openssl pkcs12 "${pkcs12_args[@]}"
fi

echo
echo "==> Subject alternative names:"
openssl x509 -in "$client_crt" -noout -text |
    awk '/Subject Alternative Name/ {getline; print}' |
    tr ',' '\n' |
    sed 's/^[[:blank:]]*/    /'

echo
echo "Register this as a trust anchor in the portal, under Settings -> Trust Anchors:"
echo
echo "    ${ca_crt}"
echo
echo "The certificate itself is ${p12} (password: ${P12_PASSWORD}). Install it with:"
echo
echo "    mise run //:x509:install-linux"
echo "    mise run //:x509:install-macos"
echo "    mise run //:x509:install-windows"
