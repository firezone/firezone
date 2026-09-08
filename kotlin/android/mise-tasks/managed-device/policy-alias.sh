#!/usr/bin/env bash
#MISE description="Have the test DPC answer the app's KeyChain requests with a certificate alias, or stop answering"
#USAGE flag "--alias <alias>" help="Alias to answer with; the DPC stops answering when omitted"
set -Eeuo pipefail
# Any failure `set -e` would swallow names itself, so no death is ever silent.
trap 'echo "error: ${BASH_SOURCE[0]}:${LINENO}: command failed with exit $?: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_parsed_flags "$@"

require_adb
require_owner

if [ -z "${usage_alias:-}" ]; then
    echo "==> Leaving certificate requests to the user..."
    provision -a dev.firezone.dpc.SET_POLICY_ALIAS
else
    echo "==> Answering certificate requests with ${usage_alias}..."
    provision -a dev.firezone.dpc.SET_POLICY_ALIAS --es alias "$usage_alias"
fi

echo
echo "==> Restart the app to pick it up:"
echo "    adb shell am force-stop ${APP_PACKAGE}"
echo "    adb shell am start -n ${APP_PACKAGE}/.core.presentation.MainActivity"
