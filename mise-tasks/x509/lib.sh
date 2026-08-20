# shellcheck shell=bash

# Helpers shared by the `x509:install-*` tasks next to this file.
#
# Sourced, never run: it carries no `#MISE description=` line and is not executable, so mise does not
# offer it as a task, and it leaves `set -euo pipefail` to the task that sources it.

CERT_ALIAS="${CERT_ALIAS:-firezone-client}"
CERT_SUBJECT_CN="${CERT_SUBJECT_CN:-dev.firezone.device-trust}"
P12_PASSWORD="${P12_PASSWORD:-firezone}"
P12_PATH="${P12_PATH:-${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509/${CERT_ALIAS}.p12}"

# One task per platform, so running the wrong one is a mistake worth naming rather than a confusing
# failure further down.
# Matched as a regular expression rather than a `case` pattern, because a `case` pattern is parsed
# before the variable holding it is expanded, so an alternation arriving this way would be matched
# as the literal characters `|` and a space. Windows needs one, reporting MINGW, MSYS or CYGWIN.
require_os() {
    local expression="$1" keystore="$2" os

    os="$(uname -s)"

    if [[ "$os" =~ $expression ]]; then
        return 0
    fi

    echo "error: this task installs into ${keystore}, but this is ${os}." >&2
    echo "'mise tasks' lists the task for this platform." >&2
    exit 1
}

require_p12() {
    if [ ! -f "$P12_PATH" ]; then
        echo "error: ${P12_PATH} does not exist; run 'mise run //:x509:gen-certificate' first" >&2
        exit 1
    fi
}
