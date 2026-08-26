#!/usr/bin/env bash
#MISE description="Stage the test client certificate for the work profile's KeyChain"
#USAGE flag "--name <name>" help="Name `//:x509:gen-certificate` stored the certificate under [default: firezone-client]"
#USAGE flag "--password <password>" help="PKCS#12 password the certificate was packed with [default: firezone]"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

# The work profile installs the same certificate as every other test device: one issued by
# `//:x509:gen-certificate` from the CA the portal trusts. Which claims it carries is that task's
# business, so testing a device certificate against a user certificate is a matter of which
# subcommand issued this file.
name="${usage_name:-firezone-client}"
password="${usage_password:-firezone}"
p12="$(client_certificate_path "$name")"

require_sdk_tool adb

command -v openssl >/dev/null || {
    echo "error: openssl is not installed" >&2
    exit 1
}

require_client_certificate "$p12"

client_cert="$(openssl pkcs12 -in "$p12" -passin "pass:${password}" -nokeys -clcerts 2>/dev/null)" || {
    echo "error: could not read ${p12}; pass --password if it was packed with another one" >&2
    exit 1
}

san="$(printf '%s\n' "$client_cert" |
    openssl x509 -noout -text |
    awk '/Subject Alternative Name/ {getline; print}' |
    tr ',' '\n' |
    sed 's/^[[:blank:]]*//')"

echo "==> Subject alternative names:"
printf '%s\n' "$san" | sed 's/^/    /'

# The portal matches a device by the identifiers in its certificate, so one issued elsewhere
# describes that machine rather than this emulator. Both reads are best-effort: a certificate
# without a serial, or a device adb cannot single out, leaves nothing to compare.
cert_serial="$(printf '%s\n' "$san" | sed -n 's|^URI:firezone://serial/||p' | head -1)"
device_serial="$(adb shell getprop ro.serialno 2>/dev/null | tr -d '\r\n' || true)"

if [ -n "$cert_serial" ] && [ -n "$device_serial" ] && [ "$cert_serial" != "$device_serial" ]; then
    echo
    echo "warning: the certificate attests ${cert_serial}, but this device reports ${device_serial}."
    echo "         Issue one that matches with:"
    echo
    echo "             mise run //:x509:gen-certificate device --serial ${device_serial}"
fi

user_id="$(require_work_profile_user)" || exit 1

# The DPC's file picker only sees the work profile's own storage, and `adb push` writes user 0's.
# The AOSP images are userdebug, so `adb root` can put the file where the profile can reach it.
staged=0
echo
echo "==> Staging the certificate in the work profile's Downloads..."
if adb_root; then
    adb push "$p12" "/data/local/tmp/${name}.p12" >/dev/null
    if adb shell mkdir -p "/data/media/${user_id}/Download" &&
        adb shell cp "/data/local/tmp/${name}.p12" "/data/media/${user_id}/Download/${name}.p12" &&
        adb shell restorecon -R "/data/media/${user_id}/Download"; then
        staged=1
    fi
fi

echo
echo "The rest cannot be scripted: installing a key pair into the KeyChain is a profile-owner API"
echo "and no adb command exposes it. Do this by hand in the emulator:"
echo
if [ "$staged" = "1" ]; then
    echo "  The file is already at Download/${name}.p12 inside the work profile."
else
    echo "  Staging into the work profile's storage failed. Copy ${p12} onto the device yourself,"
    echo "  e.g. by dragging it onto the emulator window, before starting."
fi
echo
echo "  1. Open TestDPC in the work profile (the badged icon in the launcher)."
echo "  2. Pick 'Manage certificates' and then 'Install KeyPair'."
echo "  3. Choose Download/${name}.p12 and enter the password: ${password}"
echo "  4. When asked for an alias, type exactly: ${name}"
echo "  5. Do NOT use 'Grant KeyPair to app' afterwards. Withholding that grant is the whole"
echo "     point: it is the state a personally-owned device is in, and it is what sends the app"
echo "     to the certificate screen."
echo
echo "  Alternative without the DPC, same end state: in the work profile's Settings, go to"
echo "  Security & privacy, Encryption & credentials, 'Install a certificate', 'VPN & app user"
echo "  certificate', pick the file and name it ${name}."
echo
echo "==> Next: mise run //kotlin/android:work-profile:managed-config"
