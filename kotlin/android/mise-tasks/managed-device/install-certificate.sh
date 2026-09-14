#!/usr/bin/env bash
#MISE description="Install a client certificate into the device's KeyChain, granted to the app or not"
#USAGE flag "--alias <alias>" help="KeyChain alias to install under, and the name `//:x509:gen-certificate` stored it as [default: firezone-client]"
#USAGE flag "--password <password>" help="PKCS#12 password the certificate was packed with [default: firezone]"
#USAGE flag "--file <file>" help="PKCS#12 to install; read from the certificate cache when omitted"
#USAGE flag "--no-grant" help="Withhold the key from the app, which is what an administrator of a personally-owned device can do"
set -Eeuo pipefail
# Any failure `set -e` would swallow names itself, so no death is ever silent.
trap 'echo "error: ${BASH_SOURCE[0]}:${LINENO}: command failed with exit $?: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_parsed_flags "$@"

alias_name="${usage_alias:-firezone-client}"
password="${usage_password:-firezone}"
p12="${usage_file:-$(certificate_dir)/${alias_name}.p12}"

require_adb
require_owner

if [ ! -f "$p12" ]; then
    echo "error: no certificate at ${p12}. Issue one:" >&2
    echo "           mise run //:x509:gen-certificate device --alias ${alias_name}" >&2
    exit 1
fi

# An intent extra carries the certificate, which keeps it out of `/data/local/tmp` where the DPC
# could not read it anyway.
if [ "${usage_no_grant:-}" = "true" ]; then
    echo "==> Installing '${alias_name}', granted to nobody..."
    provision -a dev.firezone.dpc.INSTALL_KEY_PAIR \
        --es alias "$alias_name" --es password "$password" --es p12 "$(base64 -w0 "$p12")"
    echo
    echo "    The app cannot get a key for this alias, so it asks the user to release it."
else
    echo "==> Installing '${alias_name}', granted to ${APP_PACKAGE}..."
    provision -a dev.firezone.dpc.INSTALL_KEY_PAIR \
        --es alias "$alias_name" --es password "$password" --es p12 "$(base64 -w0 "$p12")" \
        --es grantTo "$APP_PACKAGE"
fi

echo
echo "==> Next: mise run //kotlin/android:managed-device:managed-config --alias ${alias_name}"
