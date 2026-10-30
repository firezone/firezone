#!/usr/bin/env bash
#MISE description="Create the throwaway test CA that client certificates are issued from"
#USAGE flag "--force" help="Replace an existing CA without asking"
set -euo pipefail

# The CA private key is written below, so nobody else on the machine may read it.
umask 077

OUT_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509"

command -v openssl >/dev/null || {
    echo "error: openssl is not installed" >&2
    exit 1
}

ca_crt="${OUT_DIR}/ca.crt"
ca_key="${OUT_DIR}/ca.key"

if { [ -f "$ca_crt" ] || [ -f "$ca_key" ]; } && [ "${usage_force:-}" != "true" ]; then
    # Only a person can weigh up what replacing the CA costs, so an unattended run has to
    # say `--force` rather than be asked.
    if [ ! -t 0 ]; then
        echo "error: a test CA already exists in ${OUT_DIR}; pass --force to replace it" >&2
        exit 1
    fi

    echo "A test CA already exists in ${OUT_DIR}."
    echo
    echo "Replacing it invalidates every certificate the portal already trusts: the portal keeps"
    echo "trusting the old CA until the new one is registered there, and every certificate issued"
    echo "from the old one has to be issued again."
    echo
    read -r -p "Replace it? [y/N] " reply

    case "$reply" in
    [yY] | [yY][eE][sS]) ;;
    *)
        echo "Kept the existing CA." >&2
        exit 1
        ;;
    esac
fi

mkdir -p "$OUT_DIR"

# Everything goes through a config file rather than `-addext`, so this also runs against the
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

echo "==> Generating a test CA in ${OUT_DIR}..."
# The serial counter belongs to whichever CA was here before, so the new one starts its own.
rm -f "${OUT_DIR}/ca.srl"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "${OUT_DIR}/ca.cnf" \
    -keyout "$ca_key" \
    -out "$ca_crt" 2>/dev/null

openssl x509 -in "$ca_crt" -noout -subject -enddate -fingerprint -sha256 |
    sed 's/^/    /'

echo
echo "Register it as a trust anchor in the portal, under Settings -> Trust Anchors:"
echo
echo "    mise run //:x509:print-ca | pbcopy"
echo
echo "Then issue certificates from it:"
echo
echo "    mise run //:x509:gen-certificate device"
echo
echo "Give other test devices the same CA, so one trust anchor in the portal covers them all:"
echo
echo "    mise run //:x509:export-ca"
