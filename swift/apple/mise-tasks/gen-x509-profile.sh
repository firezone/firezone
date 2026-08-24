#!/usr/bin/env bash
#MISE description="Write a .mobileconfig that gives the Client the test X.509 identity"
#USAGE flag "--alias <alias>" help="Name `//:x509:gen-certificate` stored the key under [default: firezone-client]"
#USAGE flag "--password <password>" help="PKCS#12 export password [default: firezone]"
set -euo pipefail

# The profile embeds a private key, so nobody else on the machine may read it.
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
XCCONFIG="${APPLE_DIR}/Firezone/xcconfig/config.xcconfig"

CERT_ALIAS="${usage_alias:-firezone-client}"
P12_PASSWORD="${usage_password:-firezone}"
OUT_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509"
P12_PATH="${OUT_DIR}/${CERT_ALIAS}.p12"
PROFILE_PATH="${OUT_DIR}/${CERT_ALIAS}.mobileconfig"

FIREZONE_APP="${FIREZONE_APP:-/Applications/Firezone.app}"

xcconfig_setting() {
    sed -n "s/^[[:blank:]]*$1[[:blank:]]*=[[:blank:]]*//p" "$XCCONFIG" | head -n 1
}

# Read rather than hardcoded, so a developer signing with their own team and bundle identifier
# gets a profile that matches the app they actually build.
APP_BUNDLE_ID="${APP_BUNDLE_ID:-$(xcconfig_setting MAIN_APP_BUNDLE_ID)}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(xcconfig_setting DEVELOPMENT_TEAM)}"
EXTENSION_BUNDLE_ID="${EXTENSION_BUNDLE_ID:-${APP_BUNDLE_ID}.network-extension}"

command -v openssl >/dev/null || {
    echo "error: openssl is not installed" >&2
    exit 1
}

command -v uuidgen >/dev/null || {
    echo "error: uuidgen is not installed" >&2
    exit 1
}

if [ -z "$APP_BUNDLE_ID" ] || [ -z "$DEVELOPMENT_TEAM" ]; then
    echo "error: ${XCCONFIG} declares no MAIN_APP_BUNDLE_ID or DEVELOPMENT_TEAM;" >&2
    echo "set APP_BUNDLE_ID and DEVELOPMENT_TEAM to the ones the app is built with" >&2
    exit 1
fi

if [ ! -f "$P12_PATH" ]; then
    echo "error: ${P12_PATH} does not exist; run 'mise run //:x509:gen-certificate' first" >&2
    exit 1
fi

# The bundled network extension, whose code signature the VPN payload has to pin.
extension_bundle="${FIREZONE_APP}/Contents/Library/SystemExtensions/${EXTENSION_BUNDLE_ID}.systemextension"

# A locally signed build and a released one satisfy different requirements, so the installed
# extension is asked for its own rather than being held to a guess. The fallback accepts any
# build signed by this team, which is what a developer switching between the two needs.
designated_requirement() {
    local requirement=""

    if [ -d "$extension_bundle" ] && command -v codesign >/dev/null; then
        requirement="$(codesign --display --requirements - "$extension_bundle" 2>/dev/null |
            sed -n 's/^designated => //p')"
    fi

    if [ -n "$requirement" ]; then
        printf '%s\n' "$requirement"
        return 0
    fi

    printf 'identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"\n' \
        "$EXTENSION_BUNDLE_ID" "$DEVELOPMENT_TEAM"
}

PROVIDER_DESIGNATED_REQUIREMENT="${PROVIDER_DESIGNATED_REQUIREMENT:-$(designated_requirement)}"

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Both payloads carry their own UUID, and the VPN payload names the certificate payload's:
# that reference is what turns the identity into `NEVPNProtocol.identityReference`, which is
# the only thing the Client reads to find its certificate.
profile_uuid="$(uuidgen)"
certificate_uuid="$(uuidgen)"
vpn_uuid="$(uuidgen)"

# `<data>` ignores the line breaks openssl wraps at.
certificate_base64="$(openssl base64 -in "$P12_PATH" | sed 's/^/            /')"

escaped_password="$(xml_escape "$P12_PASSWORD")"
escaped_app_bundle_id="$(xml_escape "$APP_BUNDLE_ID")"
escaped_extension_bundle_id="$(xml_escape "$EXTENSION_BUNDLE_ID")"
escaped_requirement="$(xml_escape "$PROVIDER_DESIGNATED_REQUIREMENT")"

mkdir -p "$OUT_DIR"

cat >"$PROFILE_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadIdentifier</key>
    <string>${escaped_app_bundle_id}.test-x509</string>
    <key>PayloadUUID</key>
    <string>${profile_uuid}</string>
    <key>PayloadDisplayName</key>
    <string>Firezone test client certificate</string>
    <key>PayloadDescription</key>
    <string>Installs a throwaway Firezone client certificate and the VPN configuration that uses it. For development only.</string>
    <key>PayloadOrganization</key>
    <string>Firezone</string>
    <!-- The macOS network extension is a system extension and runs as root, whose keychain
         search list is the System keychain rather than anyone's login keychain. -->
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.security.pkcs12</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>${escaped_app_bundle_id}.test-x509.certificate</string>
            <key>PayloadUUID</key>
            <string>${certificate_uuid}</string>
            <key>PayloadDisplayName</key>
            <string>Firezone test client certificate</string>
            <key>PayloadCertificateFileName</key>
            <string>${CERT_ALIAS}.p12</string>
            <key>PayloadContent</key>
            <data>
${certificate_base64}
            </data>
            <key>Password</key>
            <string>${escaped_password}</string>
            <!-- Without this the key is usable only after someone confirms a prompt. The
                 Network Extension has no UI and could never answer one. -->
            <key>AllowAllAppsAccess</key>
            <true/>
        </dict>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.vpn.managed</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>${escaped_app_bundle_id}.test-x509.vpn</string>
            <key>PayloadUUID</key>
            <string>${vpn_uuid}</string>
            <key>PayloadDisplayName</key>
            <string>Firezone</string>
            <key>UserDefinedName</key>
            <string>Firezone</string>
            <key>VPNType</key>
            <string>VPN</string>
            <!-- The app containing the provider, not the provider itself. -->
            <key>VPNSubType</key>
            <string>${escaped_app_bundle_id}</string>
            <key>VPN</key>
            <dict>
                <key>RemoteAddress</key>
                <string>Firezone</string>
                <key>AuthenticationMethod</key>
                <string>Certificate</string>
                <key>PayloadCertificateUUID</key>
                <string>${certificate_uuid}</string>
                <key>ProviderBundleIdentifier</key>
                <string>${escaped_extension_bundle_id}</string>
                <key>ProviderType</key>
                <string>packet-tunnel</string>
                <key>ProviderDesignatedRequirement</key>
                <string>${escaped_requirement}</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "==> Wrote ${PROFILE_PATH}"
echo
echo "It carries the certificate and its password, so treat the file as private key material."
echo
echo "The VPN configuration in it names"
echo
echo "    ${EXTENSION_BUNDLE_ID}"
echo
echo "which is the one the app looks for, so the app adopts this configuration rather than adding"
echo "a second one beside it."
echo
echo "The extension is pinned to:"
echo
echo "    ${PROVIDER_DESIGNATED_REQUIREMENT}"
echo
if [ ! -d "$extension_bundle" ]; then
    echo "which is every build signed by team ${DEVELOPMENT_TEAM}, because ${FIREZONE_APP} is not"
    echo "installed to read the real one off. Install the app and run this again to pin it exactly."
    echo
fi
echo "Install the profile with:"
echo
echo "    open '${PROFILE_PATH}'"
echo
echo "That does not install it. macOS only queues it, and you finish in System Settings ->"
echo "General -> Device Management, where it waits under 'Downloaded' (Privacy & Security ->"
echo "Profiles on Ventura and Sonoma). Open it there and approve it, which asks for an"
echo "administrator password because the identity goes into the System keychain. Do it promptly:"
echo "macOS discards a downloaded profile that is left sitting."
echo
echo "Then launch Firezone and open Settings. The Certificate section reports what the"
echo "app made of the identity. Removing the profile in Device Management takes the certificate"
echo "and the VPN configuration back out with it."
