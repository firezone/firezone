#!/usr/bin/env bash
# Throwaway: finds out whether a CI emulator can be put into the states an X.509-managed device
# can be in. Installing a key pair and pushing managed configuration are owner-only APIs with no
# `adb` equivalent, so a Device Policy Controller has to make the calls.
set -euo pipefail

APP=dev.firezone.android
DPC=dev.firezone.dpc
ADMIN="${DPC}/${DPC}.AdminReceiver"
GRANTED=firezone-granted
UNGRANTED=firezone-ungranted
PASSWORD=firezone
WORK="$(mktemp -d)"

# `installKeyPair` only needs a parsable certificate and nothing here ever presents it to a portal,
# so a self-signed throwaway issued on the spot keeps key material out of the repository.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=dev.firezone.device-trust" \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -passout "pass:${PASSWORD}" -out "${WORK}/client.p12"
p12="$(base64 -w0 "${WORK}/client.p12")"

echo "==> Building..."
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest :dpc:assembleDebug \
    -Pandroid.injected.build.abi=x86_64

find_apk() {
    find app/build/intermediates/apk app/build/outputs/apk -type f -name "$1" -exec ls -t {} + 2>/dev/null | head -1
}

app_apk="$(find_apk '*debug.apk' | grep -v androidTest || true)"
[ -n "$app_apk" ] || app_apk="$(find app/build -type f -name '*-debug.apk' ! -name '*androidTest*' -exec ls -t {} + | head -1)"
test_apk="$(find app/build -type f -name '*androidTest*.apk' -exec ls -t {} + | head -1)"
dpc_apk="$(find dpc/build -type f -name '*.apk' -exec ls -t {} + | head -1)"

echo "    app:  ${app_apk}"
echo "    test: ${test_apk}"
echo "    dpc:  ${dpc_apk}"

# `-t` because an injected-ABI build is marked `android:testOnly`. Installing by hand rather than
# through `connectedDebugAndroidTest` keeps a reinstall from landing after the key grant.
adb install -r -g -t "$app_apk"
adb install -r -g -t "$test_apk"
adb install -r -g -t "$dpc_apk"

echo "==> Firezone packages on the device:"
adb shell pm list packages | grep firezone || echo "    none"

echo "==> Owners before:"
adb shell dpm list-owners || true

echo "==> Making the DPC the device owner..."
adb shell dpm set-device-owner "$ADMIN"

echo "==> Owners after:"
adb shell dpm list-owners || true

# FLAG_INCLUDE_STOPPED_PACKAGES: a freshly installed app receives no broadcast otherwise.
provision() {
    local out
    out="$(adb shell am broadcast -f 0x00000020 -n "${DPC}/.ProvisionReceiver" "$@")"
    echo "    ${out}"
    # The receiver reports failure as a non-zero result code, which `am` prints rather than exits on.
    case "$out" in
    *"result=0"*) ;;
    *)
        echo "provisioning failed" >&2
        exit 1
        ;;
    esac
}

echo "==> Installing a key pair granted to ${APP}..."
provision -a dev.firezone.dpc.INSTALL_KEY_PAIR \
    --es alias "$GRANTED" --es p12 "$p12" --es password "$PASSWORD" --es grantTo "$APP"

echo "==> Installing a key pair granted to nobody..."
provision -a dev.firezone.dpc.INSTALL_KEY_PAIR \
    --es alias "$UNGRANTED" --es p12 "$p12" --es password "$PASSWORD"

echo "==> Pushing managed configuration..."
provision -a dev.firezone.dpc.SET_RESTRICTIONS \
    --es package "$APP" --es key x509CertificateAlias --es value "$GRANTED"

echo "==> Probing what the app can see..."
result="$(adb shell am instrument -w \
    -e class dev.firezone.android.x509.DevicePolicyProbeTest \
    "${APP}.test/dev.firezone.android.core.HiltTestRunner")"
echo "$result"

# `am instrument` reports test failures in its output and still exits 0.
case "$result" in
*"OK ("*) echo "==> All probes passed." ;;
*)
    echo "==> Probes failed." >&2
    exit 1
    ;;
esac
