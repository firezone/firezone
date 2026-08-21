#!/usr/bin/env bash
#MISE description="Issue a throwaway X.509 client certificate and pack it as a PKCS#12"
#USAGE cmd "user" help="Carries an actor, so a Client can sign in as a portal identity" {
#USAGE     flag "--email <email>" help="Actor email to put in the certificate" required=#true
#USAGE     flag "--account-id <account_id>" help="Account UUID to put in the certificate" required=#true
#USAGE     flag "--serial <serial>" help="Device serial to attest as; read from this machine when omitted"
#USAGE     flag "--alias <alias>" help="Name the key is stored under [default: firezone-client]"
#USAGE     flag "--password <password>" help="PKCS#12 export password [default: firezone]"
#USAGE     flag "--regenerate-ca" help="Throw the existing CA away; invalidates certificates the portal already trusts"
#USAGE }
#USAGE cmd "device" help="Carries no actor, so the certificate can only attest the device" {
#USAGE     flag "--serial <serial>" help="Device serial to attest as; read from this machine when omitted"
#USAGE     flag "--alias <alias>" help="Name the key is stored under [default: firezone-client]"
#USAGE     flag "--password <password>" help="PKCS#12 export password [default: firezone]"
#USAGE     flag "--regenerate-ca" help="Throw the existing CA away; invalidates certificates the portal already trusts"
#USAGE }
set -euo pipefail

# Everything written below is private key material, so nobody else on the machine may read it.
umask 077

# The Clients only consider a certificate whose subject common name is this one, and read
# everything else about it out of URI subject alternative names of the form
# `firezone://<attribute>/<value>`.
SUBJECT_CN="dev.firezone.device-trust"

OUT_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509"

command -v openssl >/dev/null || {
    echo "error: openssl is not installed" >&2
    exit 1
}

# OEM placeholders the portal discards, so reading one is the same as reading nothing.
is_placeholder_serial() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    "to be filled by o.e.m." | "to be filled by oem" | "default string" | \
        "system serial number" | "systemserialnumb" | "none" | "n/a" | \
        "not specified" | "not applicable" | "invalid" | "oem_serial" | "eval")
        return 0
        ;;
    *) return 1 ;;
    esac
}

# Reading the serial needs root on Linux and is best-effort everywhere, hence `--serial`.
read_machine_serial() {
    local serial=""

    case "$(uname -s)" in
    Darwin)
        serial="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
            awk -F'"' '/IOPlatformSerialNumber/ { print $4 }')"
        ;;
    Linux)
        serial="$(cat /sys/class/dmi/id/product_serial 2>/dev/null || true)"
        ;;
    esac

    serial="$(printf '%s' "$serial" | tr -d '[:space:]')"

    if [ -z "$serial" ] || is_placeholder_serial "$serial"; then
        return 1
    fi

    printf '%s' "$serial"
}

if [ -z "${usage_cmd:-}" ]; then
    echo "error: expected 'user' or 'device'; see 'mise run //:x509:gen-certificate --help'" >&2
    exit 1
fi

kind="$usage_cmd"
alias="${usage_alias:-firezone-client}"
password="${usage_password:-firezone}"

if [ -n "${usage_serial:-}" ]; then
    serial="$usage_serial"
elif serial="$(read_machine_serial)"; then
    echo "==> Read this machine's serial: ${serial}"
else
    # Every identifier the portal recognises is a device identifier; an actor alone does not
    # satisfy `device_identifiers/1`, so a certificate without one is refused whatever its kind.
    echo "error: could not read this machine's serial; pass --serial <serial>" >&2
    exit 1
fi

ca_crt="${OUT_DIR}/ca.crt"
ca_key="${OUT_DIR}/ca.key"
client_crt="${OUT_DIR}/${alias}.crt"
client_key="${OUT_DIR}/${alias}.key"
p12="${OUT_DIR}/${alias}.p12"

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
CN = ${SUBJECT_CN}

[client_ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
subjectAltName = @san

[san]
URI.1 = firezone://serial/${serial}
EOF

if [ "$kind" = "user" ]; then
    cat >>"${OUT_DIR}/client.cnf" <<EOF
URI.2 = firezone://email/${usage_email:?}
URI.3 = firezone://account-id/${usage_account_id:?}
EOF
fi

# The CA outlives a single run: it is the trust anchor registered in the portal, and issuing a
# second certificate must not invalidate the one that is already registered there.
if [ "${usage_regenerate_ca:-}" = "true" ] || [ ! -f "$ca_crt" ] || [ ! -f "$ca_key" ]; then
    echo "==> Generating a test CA in ${OUT_DIR}..."
    rm -f "${OUT_DIR}/ca.srl"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -config "${OUT_DIR}/ca.cnf" \
        -keyout "$ca_key" \
        -out "$ca_crt" 2>/dev/null
else
    echo "==> Reusing the test CA in ${OUT_DIR}"
fi

echo "==> Issuing a ${kind} certificate as ${SUBJECT_CN}..."
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
    -name "$alias"
    -passout "pass:${password}"
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
echo "Register the CA as a trust anchor in the portal, under Settings -> Trust Anchors:"
echo
echo "    mise run //:x509:print-ca | pbcopy"
echo
echo "The certificate itself is ${p12} (password: ${password}). Install it with:"
echo
echo "    mise run //:x509:install-linux"
echo "    mise run //:x509:install-windows"
echo
echo "The Apple Clients read no keystore of their own: their identity comes from the VPN"
echo "configuration a profile installs. Write one with:"
echo
echo "    mise run //swift/apple:gen-x509-profile"
