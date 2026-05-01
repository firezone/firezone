#!/usr/bin/env bash
#MISE description="Inspect/toggle UserDefaults and wipe the macOS keychain token (dev helper)"
set -euo pipefail

BUNDLE_ID="dev.firezone.firezone"
TOKEN_LABEL_RELEASE="Firezone token"
TOKEN_LABEL_DEBUG="Firezone token (debug)"

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
else
    C_RESET=""
    C_GREEN=""
    C_RED=""
    C_YELLOW=""
    C_DIM=""
    C_BOLD=""
fi

BOOL_KEYS=(
    connectOnStart
    startOnLogin
    disableUpdateCheck
    internetResourceEnabled
    hideAdminPortalMenuItem
    hideResourceList
)

STRING_KEYS=(
    authURL
    apiURL
    logFilter
    accountSlug
    supportURL
)

usage() {
    cat <<EOF
Usage: ${0##*/} [command] [args]

Running with no command drops you into an interactive view: press a
number to flip the corresponding bool, 'w'/'W' to wipe the debug/release
keychain token, 'r' to reset all UserDefaults, 'q' to quit.

Commands:
  (no args)             Interactive mode (numbered toggles, single-keypress)
  status                Show all toggles + keychain state with colour-coded values
  set <key> <value>     Set a UserDefault (auto-detects bool vs string)
  unset <key>           Clear a UserDefault (revert to app default)
  reset                 Clear every managed UserDefault (revert to app defaults)
  wipe-token            Delete both debug and release Firezone tokens
  wipe-token-debug      Delete only the debug Firezone token
  wipe-token-release    Delete only the release Firezone token
  help                  Show this help

Examples:
  ${0##*/}
  ${0##*/} status
  ${0##*/} set connectOnStart true
  ${0##*/} unset accountSlug
  ${0##*/} wipe-token-debug
EOF
}

main() {
    if (($# == 0)); then
        cmd_interactive
        return
    fi
    local cmd="$1"
    shift
    case "${cmd}" in
    status) cmd_status ;;
    set) cmd_set "$@" ;;
    unset) cmd_unset "$@" ;;
    reset) cmd_reset ;;
    wipe-token) cmd_wipe_token ;;
    wipe-token-debug) wipe_token_label "${TOKEN_LABEL_DEBUG}" ;;
    wipe-token-release) wipe_token_label "${TOKEN_LABEL_RELEASE}" ;;
    interactive) cmd_interactive ;;
    help | -h | --help) usage ;;
    *)
        echo "unknown command: ${cmd}" >&2
        usage
        exit 2
        ;;
    esac
}

cmd_status() {
    printf '%sBundle:%s %s\n\n' "${C_BOLD}" "${C_RESET}" "${BUNDLE_ID}"

    printf '%sBool toggles%s\n' "${C_BOLD}" "${C_RESET}"
    local key
    for key in "${BOOL_KEYS[@]}"; do
        print_default_row "${key}" bool
    done

    printf '\n%sString settings%s\n' "${C_BOLD}" "${C_RESET}"
    for key in "${STRING_KEYS[@]}"; do
        print_default_row "${key}" string
    done

    printf '\n%sKeychain%s\n' "${C_BOLD}" "${C_RESET}"
    print_keychain_row "${TOKEN_LABEL_RELEASE}"
    print_keychain_row "${TOKEN_LABEL_DEBUG}"
}

cmd_set() {
    local key="${1:-}"
    local value="${2:-}"
    if [[ -z "${key}" || -z "${value}" ]]; then
        echo "set requires <key> <value>" >&2
        exit 2
    fi

    if is_bool_key "${key}"; then
        case "${value}" in
        true | yes | 1) defaults write "${BUNDLE_ID}" "${key}" -bool true ;;
        false | no | 0) defaults write "${BUNDLE_ID}" "${key}" -bool false ;;
        *)
            echo "bool key '${key}' expects true/false, got '${value}'" >&2
            exit 2
            ;;
        esac
    elif is_string_key "${key}"; then
        defaults write "${BUNDLE_ID}" "${key}" -string "${value}"
    else
        echo "unknown key '${key}'. Run 'status' to see valid keys." >&2
        exit 2
    fi

    flush_prefs_cache
    echo "set ${key} = ${value}"
}

cmd_unset() {
    local key="${1:-}"
    if [[ -z "${key}" ]]; then
        echo "unset requires <key>" >&2
        exit 2
    fi
    defaults delete "${BUNDLE_ID}" "${key}" 2>/dev/null || true
    flush_prefs_cache
    echo "unset ${key}"
}

cmd_wipe_token() {
    local label
    for label in "${TOKEN_LABEL_RELEASE}" "${TOKEN_LABEL_DEBUG}"; do
        wipe_token_label "${label}"
    done
}

# The Network Extension runs as root, so any token it writes lands in
# /Library/Keychains/System.keychain. The login keychain is searched too,
# in case the main app (running as the user) wrote a copy there.
# Looping handles duplicates that can accumulate across builds.
wipe_token_label() {
    local label="$1"
    local removed=0
    local keychain_path
    while keychain_path="$(find_keychain_for_label "${label}")" && [[ -n "${keychain_path}" ]]; do
        if [[ "${keychain_path}" == "/Library/Keychains/System.keychain" ]]; then
            if ((removed == 0)); then
                printf 'note: %s lives in the System keychain; macOS will show an auth dialog\n' "${label}"
            fi
            if ! delete_with_gui_auth "${label}" "${keychain_path}"; then
                printf '  failed to remove %s from %s (cancelled or denied?)\n' "${label}" "${keychain_path}" >&2
                return
            fi
        else
            if ! security delete-generic-password -l "${label}" "${keychain_path}" >/dev/null 2>&1; then
                printf '  failed to remove %s from %s\n' "${label}" "${keychain_path}" >&2
                return
            fi
        fi
        removed=$((removed + 1))
    done

    if ((removed > 0)); then
        printf '  removed %s\n' "${label}"
    else
        printf '  %s already absent\n' "${label}"
    fi
}

find_keychain_for_label() {
    security find-generic-password -l "$1" 2>/dev/null |
        sed -n 's/^keychain: "\(.*\)"$/\1/p' |
        head -n1
}

# Run `security delete-generic-password` as root via the macOS GUI auth
# dialog (instead of terminal sudo). osascript's `do shell script ... with
# administrator privileges` triggers the standard system Authorization
# Services prompt — Touch ID / password / admin user, no terminal needed.
delete_with_gui_auth() {
    local label="$1"
    local keychain_path="$2"
    local shell_cmd
    shell_cmd="$(printf 'security delete-generic-password -l %q %q' "${label}" "${keychain_path}")"
    # Escape for AppleScript string literal: backslash first, then quote.
    local applescript_cmd="${shell_cmd//\\/\\\\}"
    applescript_cmd="${applescript_cmd//\"/\\\"}"
    osascript -e "do shell script \"${applescript_cmd}\" with administrator privileges" >/dev/null 2>&1
}

cmd_reset() {
    local key
    for key in "${BOOL_KEYS[@]}" "${STRING_KEYS[@]}"; do
        defaults delete "${BUNDLE_ID}" "${key}" 2>/dev/null || true
    done
    flush_prefs_cache
    echo "reset all managed UserDefaults to app defaults"
}

is_bool_key() {
    local needle="$1"
    local candidate
    for candidate in "${BOOL_KEYS[@]}"; do
        [[ "${candidate}" == "${needle}" ]] && return 0
    done
    return 1
}

is_string_key() {
    local needle="$1"
    local candidate
    for candidate in "${STRING_KEYS[@]}"; do
        [[ "${candidate}" == "${needle}" ]] && return 0
    done
    return 1
}

print_default_row() {
    local key="$1"
    local kind="$2"
    local display="${3:-${key}}"
    local value
    if value="$(defaults read "${BUNDLE_ID}" "${key}" 2>/dev/null)"; then
        if [[ "${kind}" == bool ]]; then
            printf '  %-30s %s\n' "${display}" "$(format_bool "${value}")"
        else
            printf '  %-30s %s\n' "${display}" "${value}"
        fi
    else
        printf '  %-30s %s(default)%s\n' "${display}" "${C_DIM}" "${C_RESET}"
    fi
}

print_keychain_row() {
    local label="$1"
    if security find-generic-password -l "${label}" >/dev/null 2>&1; then
        printf '  %-30s %spresent%s\n' "${label}" "${C_GREEN}" "${C_RESET}"
    else
        printf '  %-30s %sabsent%s\n' "${label}" "${C_DIM}" "${C_RESET}"
    fi
}

format_bool() {
    case "$1" in
    1 | true | YES) printf '%strue%s' "${C_GREEN}" "${C_RESET}" ;;
    0 | false | NO) printf '%sfalse%s' "${C_RED}" "${C_RESET}" ;;
    *) printf '%s%s%s' "${C_YELLOW}" "$1" "${C_RESET}" ;;
    esac
}

# `defaults` writes synchronously to the plist, but `cfprefsd` keeps an
# in-memory cache that already-running apps may consult. Killing it forces
# a re-read on next access — without this, a toggle change can appear to
# have no effect until you next reboot.
flush_prefs_cache() {
    killall cfprefsd 2>/dev/null || true
}

flip_bool() {
    local key="$1"
    local current
    current="$(defaults read "${BUNDLE_ID}" "${key}" 2>/dev/null || true)"
    case "${current}" in
    1 | true | YES) defaults write "${BUNDLE_ID}" "${key}" -bool false ;;
    *) defaults write "${BUNDLE_ID}" "${key}" -bool true ;;
    esac
    flush_prefs_cache
}

cmd_interactive() {
    if [[ ! -t 0 ]]; then
        echo "interactive mode requires a terminal" >&2
        exit 2
    fi

    trap 'printf "\n"; exit 0' INT

    while true; do
        clear
        printf '%sBundle:%s %s\n\n' "${C_BOLD}" "${C_RESET}" "${BUNDLE_ID}"

        printf '%sBool toggles%s\n' "${C_BOLD}" "${C_RESET}"
        local i
        for i in "${!BOOL_KEYS[@]}"; do
            local key="${BOOL_KEYS[i]}"
            print_default_row "${key}" bool "$((i + 1))) ${key}"
        done

        printf '\n%sString settings%s %s(use `set` to edit)%s\n' \
            "${C_BOLD}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
        for key in "${STRING_KEYS[@]}"; do
            print_default_row "${key}" string
        done

        printf '\n%sKeychain%s\n' "${C_BOLD}" "${C_RESET}"
        print_keychain_row "${TOKEN_LABEL_RELEASE}"
        print_keychain_row "${TOKEN_LABEL_DEBUG}"

        printf '\n%s[1-%d]%s flip bool   %s[w]%s wipe debug   %s[W]%s wipe release   %s[r]%s reset all   %s[q]%s quit\n> ' \
            "${C_BOLD}" "${#BOOL_KEYS[@]}" "${C_RESET}" \
            "${C_BOLD}" "${C_RESET}" \
            "${C_BOLD}" "${C_RESET}" \
            "${C_BOLD}" "${C_RESET}" \
            "${C_BOLD}" "${C_RESET}"

        local pressed
        IFS= read -rsn1 pressed || return 0
        printf '\n'

        case "${pressed}" in
        q | Q | $'\e') return 0 ;;
        w)
            wipe_token_label "${TOKEN_LABEL_DEBUG}"
            sleep 1
            ;;
        W)
            wipe_token_label "${TOKEN_LABEL_RELEASE}"
            sleep 1
            ;;
        r | R)
            cmd_reset
            sleep 1
            ;;
        [1-9])
            local index=$((pressed - 1))
            if ((index < ${#BOOL_KEYS[@]})); then
                flip_bool "${BOOL_KEYS[index]}"
            fi
            ;;
        esac
    done
}

main "$@"
