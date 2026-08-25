#!/usr/bin/env bash
#MISE description="Export the test CA and its private key; throwaway material, never for anything real"
#USAGE flag "--out <out>" help="Where to write the bundle [default: ca.p12 beside the CA]"
#USAGE flag "--password <password>" help="PKCS#12 export password [default: firezone]"
set -euo pipefail

# The bundle carries the CA private key, so nobody else on the machine may read it.
umask 077

OUT_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509"

command -v openssl >/dev/null || {
    echo "error: openssl is not installed" >&2
    exit 1
}

ca_crt="${OUT_DIR}/ca.crt"
ca_key="${OUT_DIR}/ca.key"
out="${usage_out:-${OUT_DIR}/ca.p12}"
password="${usage_password:-firezone}"

if [ ! -f "$ca_crt" ] || [ ! -f "$ca_key" ]; then
    echo "error: no test CA in ${OUT_DIR}; run 'mise run //:x509:create-ca' first" >&2
    exit 1
fi

echo "==> Packing ${out}..."
# Whichever OpenSSL reads this back is out of our hands, so the bundle is written with the
# SHA1/3DES profile that older OpenSSL and the LibreSSL on macOS also understand. Those two
# default to it and may not know the flags, hence the retry.
pkcs12_args=(
    -export
    -inkey "$ca_key"
    -in "$ca_crt"
    -name "Firezone Test CA"
    -passout "pass:${password}"
    -out "$out"
)

if ! openssl pkcs12 "${pkcs12_args[@]}" -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null; then
    openssl pkcs12 "${pkcs12_args[@]}"
fi

# `umask` says nothing about a file that was already there, so the mode is set outright.
chmod 600 "$out"

openssl x509 -in "$ca_crt" -noout -subject -enddate -fingerprint -sha256 |
    sed 's/^/    /'

echo
echo "The bundle carries the CA private key, so treat it as private key material: move it over a"
echo "channel you trust and delete it once the other machine has it. This is a throwaway test CA"
echo "and must never be reused for anything real."
echo
echo "On the other machine, with the bundle at <path>:"
echo
echo "    mise run //:x509:import-ca --in <path> --password ${password}"
