# Firezone Apple Client

Firezone clients for macOS and iOS.

## Pre-requisites

1. Rust: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
1. Request your Firezone email added to our Apple Developer Account
1. Open Xcode, go to Settings -> Account and log in. Click "Download manual
   profiles" button.
1. Install signing keys from 1password "Engineering" vault.

Automatic signing has been disabled because it doesn't easily work with our
CI/CD pipeline.

## Building

1. Clone this repo:

   ```bash
   git clone https://github.com/firezone/firezone
   ```

1. `cd` to the Apple clients code

   ```bash
   cd swift/apple
   ```

1. Copy an appropriate xcconfig and edit as necessary:

   ```bash
   cp Firezone/xcconfig/debug.xcconfig Firezone/xcconfig/config.xcconfig
   vim Firezone/xcconfig/config.xcconfig
   ```

1. Open project in Xcode:

```bash
open Firezone.xcodeproj
```

1. Build the Firezone target

## Debugging

[This Network Extension debugging guide](https://developer.apple.com/forums/thread/725805)
is a great resource to use as a starting point.

### Debugging on ios simulator

Network Extensions
[can't be debugged](https://developer.apple.com/forums/thread/101663) in the iOS
simulator, so you'll need a physical iOS device or Mac to debug.

### NetworkExtension not loading (macOS)

Try clearing your LaunchAgent db:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -delete
```

**Note**: You MUST reboot after doing this!

### Outdated version of NetworkExtension loading

If you're making changes to the Network Extension and it doesn't seem to be
reflected when you run/debug, it could be that PluginKit is still launching your
old NetworkExtension. Try this to remove it:

```bash
pluginkit -v -m -D -i <bundle-id>
pluginkit -a <path>
pluginkit -r <path>
```

## Cleaning up

Occasionally you might encounter strange issues where it seems like the
artifacts being debugged don't match the code, among other things. In these
cases it's good to clean up using one of the methods below.

### Resetting Xcode package cache

Removes cached packages, built extensions, etc.

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData
```

### Removing build artifacts

To cleanup Swift build objects:

```bash
cd swift/apple
./cleanup.sh
```

To cleanup both Swift and Rust build objects:

```bash
cd swift/apple
./cleanup.sh all
```

### Wiping connlib log directory

```
rm -rf $HOME/Library/Group\ Containers/47R2M6779T.group.dev.firezone.firezone/Library/Caches/logs/connlib
```

### Clearing the Keychain item

Sometimes it's helpful to be able to test how the app behaves when the keychain
item is missing. You can remove the keychain item with the following command:

```bash
security delete-generic-password -s "dev.firezone.firezone"
```

## Generating new signing certificates and provisioning profiles

Certs are only good for a year, then you need to generate new ones. Since we use
GitHub CI, we have to use manually-managed signing and provisioning. Here's how
you populate the required GitHub secrets.

### Certificates

You first need two certs: The build / signing cert (Apple Distribution) and the
installer cert (Mac Installer Distribution). You can generate these in the Apple
Developer portal.

These are the secrets in GH actions:

```
APPLE_BUILD_CERTIFICATE_BASE64
APPLE_BUILD_CERTIFICATE_P12_PASSWORD
APPLE_MAC_INSTALLER_CERTIFICATE_BASE64
APPLE_MAC_INSTALLER_CERTIFICATE_P12_PASSWORD
```

How to do it:

1. Go to
   [Apple Developer](https://developer.apple.com/account/resources/certificates/list)
1. Click the "+" button to generate a new distribution certificate for App Store
1. It will ask for a CSR. Open Keychain Access, go to Keychain Access ->
   Certificate Assistant -> Request a Certificate from a Certificate Authority
   and follow the prompts. Make sure to select "save to disk" to save the CSR.
1. Upload the CSR to Apple Developer. Download the resulting certificate.
   Double-click to install it in Keychain Access.
1. Right-click the cert in Keychain access. Export the certificate, choose p12
   file. Make sure to set a password -- this is the
   `APPLE_BUILD_CERTIFICATE_P12_PASSWORD`.
1. Convert the p12 file to base64:
   ```bash
   cat cert.p12 | base64
   ```
1. Save the base64 output as `APPLE_BUILD_CERTIFICATE_BASE64`.

Repeat the steps above but choose "Mac Installer certificate" instead of
"distribution certificate" in step 2, and save the resulting base64 and password
as `APPLE_MAC_INSTALLER_CERTIFICATE_BASE64` and
`APPLE_MAC_INSTALLER_CERTIFICATE_P12_PASSWORD`.

### Provisioning profiles

```
APPLE_IOS_APP_PROVISIONING_PROFILE
APPLE_IOS_NE_PROVISIONING_PROFILE
APPLE_MACOS_APP_PROVISIONING_PROFILE
APPLE_MACOS_NE_PROVISIONING_PROFILE
```

1. Go to
   [Apple Developer](https://developer.apple.com/account/resources/profiles/list)
1. Click the "+" button to generate a new provisioning profile for App Store
1. Select the appropriate app ID and distribution certificate you just created.
   You'll need a provisioning profile for each app and network extension, so 4
   total (mac app, mac network extension, ios app, ios network extension).
1. Download the resulting provisioning profiles.
1. Encode to base64 and save each using the secrets names above:

```bash
cat profile.mobileprovision | base64
```

1. Now, you need to update the XCConfig to use these. Edit
   Firezone/xcconfig/release.xcconfig and update the provisioning profile UUIDs.
   The UUID can be found by grepping for them in the provisioning profile files
   themselves, or just opening them in a text editor and looking halfway down
   the file.
1. Now, for iOS only, you need to edit Firezone/ExportOptions.plist and update
   the provisioning profile UUIDs there as well.

### Runner keychain password

This can be randomly generated. It's only used ephemerally to load the secrets
into the runner's keychain for the build.

```
APPLE_RUNNER_KEYCHAIN_PASSWORD
```
