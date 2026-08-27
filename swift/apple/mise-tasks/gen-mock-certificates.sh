#!/usr/bin/env bash
#MISE description="Mint the mock certificates the X.509 screenshots are taken of"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$(cd "${SCRIPT_DIR}/../FirezoneKit/Sources/FirezoneKit/Mocks/Certificates" && pwd)"

# The Clients only consider a certificate whose subject common name is this one, so a mock
# spelled any other way photographs as "no certificate found".
SUBJECT_CN="dev.firezone.device-trust"

ORGANISATION="Example Corp"
ISSUER_CN="Example Corp Device CA"

# The deployment the rest of the mock fixtures describe.
ACTOR_EMAIL="jane.doe@example.com"
ACCOUNT_ID="9f9b7e2a-3c4d-4f61-8a0b-2d5e6f7a8b9c"
INTUNE_ID="5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3"
DEVICE_SERIAL="C02XK1ZGJGH5"

# Written into the certificates rather than counted off today, so the rows a screenshot shows
# are the same ones next year. `openssl ca` is here for the same reason: `openssl x509` can
# only date a certificate relative to now.
VALID_FROM="260101000000Z"
VALID_UNTIL="360101000000Z"
EXPIRED_FROM="180101000000Z"
EXPIRED_UNTIL="200101000000Z"

command -v openssl >/dev/null || {
    echo "error: openssl is not installed" >&2
    exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Everything goes through config files rather than `-addext`, so this also runs against the
# LibreSSL that macOS ships as /usr/bin/openssl.
cat >"${WORK_DIR}/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ca_ext

[dn]
O = ${ORGANISATION}
CN = ${ISSUER_CN}

[ca_ext]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat >"${WORK_DIR}/sign.cnf" <<EOF
[ca]
default_ca = mock_ca

[mock_ca]
dir = ${WORK_DIR}
database = \$dir/index.txt
new_certs_dir = \$dir/issued
serial = \$dir/serial
certificate = \$dir/ca.crt
private_key = \$dir/ca.key
default_md = sha256
policy = leaf_policy

[leaf_policy]
organizationName = supplied
commonName = supplied
EOF

mkdir -p "${WORK_DIR}/issued"
: >"${WORK_DIR}/index.txt"
# All three certificates share a subject, which the database rejects by default.
echo "unique_subject = no" >"${WORK_DIR}/index.txt.attr"

echo "==> Minting a throwaway ${ISSUER_CN}..."
openssl req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 7300 \
    -config "${WORK_DIR}/ca.cnf" \
    -keyout "${WORK_DIR}/ca.key" \
    -out "${WORK_DIR}/ca.crt" 2>/dev/null

issue_certificate() {
    local name="$1" serial_number="$2" serial_attribute="$3" not_before="$4" not_after="$5"
    local cnf="${WORK_DIR}/${name}.cnf"

    # The claims parser mirrors the portal and refuses an identity it only has half of, so
    # every mock carries both an actor email and the account that actor belongs to.
    cat >"$cnf" <<EOF
[req]
distinguished_name = dn
prompt = no

[dn]
O = ${ORGANISATION}
CN = ${SUBJECT_CN}

[leaf_ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
subjectAltName = @san

[san]
URI.1 = firezone://${serial_attribute}/${DEVICE_SERIAL}
URI.2 = firezone://email/${ACTOR_EMAIL}
URI.3 = firezone://account-id/${ACCOUNT_ID}
URI.4 = firezone://intune-id/${INTUNE_ID}
EOF

    echo "$serial_number" >"${WORK_DIR}/serial"

    openssl req -new -newkey rsa:2048 -nodes \
        -config "$cnf" \
        -keyout "${WORK_DIR}/${name}.key" \
        -out "${WORK_DIR}/${name}.csr" 2>/dev/null

    openssl ca -batch -notext \
        -config "${WORK_DIR}/sign.cnf" \
        -extfile "$cnf" \
        -extensions leaf_ext \
        -startdate "$not_before" \
        -enddate "$not_after" \
        -in "${WORK_DIR}/${name}.csr" \
        -out "${WORK_DIR}/${name}.crt" 2>/dev/null

    openssl x509 -in "${WORK_DIR}/${name}.crt" -outform DER -out "${OUT_DIR}/${name}.der"

    echo "==> Wrote ${OUT_DIR}/${name}.der"
}

# `serial-number` is an attribute the parser does not read, which is what keeps an
# unrecognised claim on that screen.
issue_certificate usable 1A2B3C4D5E6F7081 serial "$VALID_FROM" "$VALID_UNTIL"
issue_certificate unknown-attribute 2B3C4D5E6F708192 serial-number "$VALID_FROM" "$VALID_UNTIL"
issue_certificate expired 3C4D5E6F708192A3 serial "$EXPIRED_FROM" "$EXPIRED_UNTIL"

echo
echo "Only the certificates are kept; the CA and the keys go out with ${WORK_DIR}."
