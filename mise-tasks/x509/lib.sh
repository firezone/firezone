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
require_os() {
    local pattern="$1" keystore="$2"

    # shellcheck disable=SC2254 # A glob on purpose: Windows reports several different names.
    case "$(uname -s)" in
    $pattern) ;;
    *)
        echo "error: this task installs into ${keystore}, but this is $(uname -s)." >&2
        echo "'mise tasks' lists the task for this platform." >&2
        exit 1
        ;;
    esac
}

require_p12() {
    if [ ! -f "$P12_PATH" ]; then
        echo "error: ${P12_PATH} does not exist; run 'mise run //:x509:gen-certificate' first" >&2
        exit 1
    fi
}
