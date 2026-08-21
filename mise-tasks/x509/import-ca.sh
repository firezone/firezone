#!/usr/bin/env bash
#MISE description="Import a test CA and its private key; throwaway material, never for anything real"
#USAGE flag "--in <in>" help="Bundle `//:x509:export-ca` wrote [default: ca.p12 beside the CA]"
#USAGE flag "--password <password>" help="PKCS#12 password of the bundle [default: firezone]"
#USAGE flag "--force" help="Replace an existing CA without asking"
set -euo pipefail

# The CA private key is unpacked below, so nobody else on the machine may read it.
umask 077

OUT_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509"

command -v openssl >/dev/null || {
    echo "error: openssl is not installed" >&2
    exit 1
}

ca_crt="${OUT_DIR}/ca.crt"
ca_key="${OUT_DIR}/ca.key"
in="${usage_in:-${OUT_DIR}/ca.p12}"
password="${usage_password:-firezone}"

if [ ! -f "$in" ]; then
    echo "error: ${in} does not exist; 'mise run //:x509:export-ca' writes one on the machine that has the CA" >&2
    exit 1
fi

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
    echo "trusting the old CA until the imported one is registered there, and every certificate"
    echo "issued from the old one has to be issued again."
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

work="$(mktemp -d)"
# shellcheck disable=SC2064 # `work` is expanded now on purpose; the trap outlives the variable.
trap "rm -rf '${work}'" EXIT

# Unpacked beside the CA rather than over it, so a bundle that turns out to be unreadable
# leaves the CA that is already here alone.
unpack() {
    openssl pkcs12 -in "$in" -passin "pass:${password}" -nokeys -clcerts 2>/dev/null |
        openssl x509 -out "${work}/ca.crt" 2>/dev/null &&
        openssl pkcs12 -in "$in" -passin "pass:${password}" -nocerts -nodes 2>/dev/null |
        openssl pkcs8 -topk8 -nocrypt -out "${work}/ca.key" 2>/dev/null
}

echo "==> Reading ${in}..."
if ! unpack || [ ! -s "${work}/ca.crt" ] || [ ! -s "${work}/ca.key" ]; then
    echo "error: ${in} holds no certificate and key; is --password right?" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
mv "${work}/ca.crt" "$ca_crt"
mv "${work}/ca.key" "$ca_key"
# The serial counter belongs to whichever CA was here before, so the imported one starts its own.
rm -f "${OUT_DIR}/ca.srl"

echo "==> Imported the CA into ${OUT_DIR}"
openssl x509 -in "$ca_crt" -noout -subject -enddate -fingerprint -sha256 |
    sed 's/^/    /'

echo
echo "This is a throwaway test CA and must never be reused for anything real. Delete the bundle"
echo "now that its key is unpacked here."
echo
echo "Register it as a trust anchor in the portal unless another machine already did:"
echo
echo "    mise run //:x509:print-ca | pbcopy"
echo
echo "Then issue this machine's certificate from it:"
echo
echo "    mise run //:x509:gen-certificate device"
