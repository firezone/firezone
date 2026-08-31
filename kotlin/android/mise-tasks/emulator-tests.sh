#!/usr/bin/env bash
#MISE description="Run the instrumented tests on an attached device from already-built APKs"
#USAGE arg "[filter]..." help="AndroidJUnitRunner arguments to narrow what runs, e.g. --annotation <class> or --notAnnotation <class>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

APK_DIR="app/build/outputs/apk"
RUNNER="dev.firezone.android.test/dev.firezone.android.core.HiltTestRunner"

find_apk() {
    find "$APK_DIR" -type f -name "$1" -exec ls -t {} + 2>/dev/null | head -1
}

app_apk="$(find_apk 'app-debug.apk')"
test_apk="$(find_apk '*androidTest.apk')"

if [ -z "$app_apk" ] || [ -z "$test_apk" ]; then
    echo "error: no APKs under ${APK_DIR}. Build them:" >&2
    echo "           ./gradlew assembleDebug assembleDebugAndroidTest" >&2
    exit 1
fi

echo "==> Installing ${app_apk}"
# `-t` because a build narrowed to one ABI is marked `android:testOnly`.
adb install -r -g -t "$app_apk"

echo "==> Installing ${test_apk}"
adb install -r -g -t "$test_apk"

# Flags are AndroidJUnitRunner's own argument names, so `--notAnnotation X` reaches it as
# `-e notAnnotation X` and its documentation reads across. Read positionally rather than through
# `#USAGE`, which only binds under `mise run` and would leave a filter silently unset when a
# workflow calls this directly.
filter=()

while [ $# -gt 0 ]; do
    case "$1" in
    --*)
        filter+=(-e "${1#--}" "$2")
        shift 2
        ;;
    *)
        echo "error: expected a flag like '--annotation <class>', got '$1'" >&2
        exit 1
        ;;
    esac
done

echo "==> Running the tests..."
# Guarded because bash 3.2, which macOS still ships, treats an empty array as unset.
result="$(adb shell am instrument -w ${filter[@]+"${filter[@]}"} "$RUNNER")"

echo "$result"

# `am instrument` reports failures in its output and exits 0 regardless.
case "$result" in
*"OK ("*) ;;
*)
    echo >&2
    echo "error: the instrumented tests did not pass" >&2
    exit 1
    ;;
esac
