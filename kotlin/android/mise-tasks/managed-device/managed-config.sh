#!/usr/bin/env bash
#MISE description="Point the app's managed configuration at a certificate alias, or clear it"
#USAGE flag "--alias <alias>" help="Alias to configure; the configuration is cleared when omitted"
set -Eeuo pipefail
# Any failure `set -e` would swallow names itself, so no death is ever silent.
trap 'echo "error: ${BASH_SOURCE[0]}:${LINENO}: command failed with exit $?: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_parsed_flags "$@"

# X509_CERTIFICATE_ALIAS_RESTRICTION in `core/data/Repository.kt`.
RESTRICTION_KEY="x509CertificateAlias"

require_adb
require_owner

if [ -z "${usage_alias:-}" ]; then
    echo "==> Clearing the app's managed configuration..."
    provision -a dev.firezone.dpc.SET_RESTRICTIONS --es package "$APP_PACKAGE"
else
    echo "==> Configuring ${RESTRICTION_KEY}=${usage_alias}..."
    provision -a dev.firezone.dpc.SET_RESTRICTIONS \
        --es package "$APP_PACKAGE" --es key "$RESTRICTION_KEY" --es value "$usage_alias"
fi

echo
echo "==> Restart the app to pick it up:"
echo "    adb shell am force-stop ${APP_PACKAGE}"
echo "    adb shell am start -n ${APP_PACKAGE}/.core.presentation.MainActivity"
