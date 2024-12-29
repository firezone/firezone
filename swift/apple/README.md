# Firezone Apple Client

Firezone clients for macOS and iOS.

This document is intended as a reference for developers working on the Apple
clients.

## Prerequisites

1. Ensure you have the latest stable version of Xcode installed and selected.
1. Rust: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
1. Request your Firezone email added to our Apple Developer Account
1. Open Xcode, go to Settings -> Account and log in.

If you're working on the macOS client, you'll need to disable SIP and enable
system extension development mode:

1. Follow
   [these instructions](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection)
   to disable SIP.
1. After that's complete, turn on system extension development mode:

```bash
systemextensionsctl developer on
```

This will prevent macOS from blocking the Network Extension from loading due to
notarization or filepath restrictions.

**Be sure to re-enable SIP to test the app in a production-like environment.**

You may consider using a macOS VM (such as Parallels Desktop) to test the
standalone macOS client, as it can be easier to test different macOS versions
and configurations without risking your main machine.

## Building

1. Add required Rust targets:

   Ensure you've activated the correct toolchain version for your local
   environment with `rustup default <toolchain>` (find this from
   `/rust/rust-toolchain.toml` file), then run:

   ```
   rustup target add aarch64-apple-ios aarch64-apple-darwin x86_64-apple-darwin
   ```

1. Clone this repo:

   ```bash
   git clone https://github.com/firezone/firezone
   ```

1. `cd` to the Apple clients code

   ```bash
   cd swift/apple
   ```

1. Open project in Xcode:

   ```bash
   open Firezone.xcodeproj
   ```

1. Build and run the `Firezone` target.

**Note**: To test the iOS app, you'll need a physical iOS device such as an
iPhone or iPad. Network Extensions can't be debugged in the iOS simulator.

### Making release builds for local testing

1. Install the needed signing certificates to your keychain by exporting them
   from 1Password and double-clicking them to install. Contact a team member if
   you need access. Once installed, you should see the distribution, developer
   ID, and installer certificates in your keychain:

   ```bash
   > security find-identity -v -p codesigning

   ...
   6) A6815986DDB2A0FA999DA89F04E4F6E0B3ACD724 "Apple Distribution: Firezone, Inc. (47R2M6779T)"
   7) 281CCA77645E0399F9E80D6190D8F412EE7BA871 "3rd Party Mac Developer Installer: Firezone, Inc. (47R2M6779T)"
   8) 8BA4CA21B9737F37397253A6AA483196033ABAE2 "Developer ID Application: Firezone, Inc. (47R2M6779T)"
       8 valid identities found
   ```

1. Download the provisioning profiles from the Apple Developer Portal and
   install them by dragging them onto the Xcode icon in the Dock.

1. Run the appropriate build script:

   ```bash
   scripts/build/ios-appstore.sh
   ```

   or

   ```bash
   scripts/build/macos-appstore.sh
   ```

   or

   ```bash
   scripts/build/macos-standalone.sh
   ```

## Debugging

[This Network Extension debugging guide](https://developer.apple.com/forums/thread/725805)
is a great resource to use as a starting point.

### Debugging on iOS simulator

Network Extensions
[can't be debugged](https://developer.apple.com/forums/thread/101663) in the iOS
simulator, so you'll need a physical iOS device to develop the iOS build on.

### NetworkExtension not loading (macOS)

If the tunnel fails to come up after signing in, it can be for a number of
reasons. Start by checking the system logs for errors -- commonly it is due to
entitlements, signing, notarization, or some other security issue.

One technique is to start a `log stream` in another terminal while replicating
the issue, looking for errors reported by other macOS subsystems hinting at why
the Network Extension failed to load.

If nothing seem obviously wrong, it could be that the Network Extension isn't
loading because of a LaunchAgent issue.

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
pluginkit -v -m -D -i dev.firezone.firezone.network-extension
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
rm -rf $HOME/Library/Group\ Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib
sudo rm -rf /private/var/root/Library/Group\ Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib
```

### Clearing the Keychain item

Sometimes it's helpful to be able to test how the app behaves when the keychain
item is missing. You can remove the keychain item with the following command:

```bash
security delete-generic-password -s "dev.firezone.firezone"
```

## Generating new signing certificates and provisioning profiles for app store distribution

App Store distribution certifications are only good for a year, then you need to
generate new ones. Since we use GitHub CI, we must manually manage signing and
provisioning since it's not possible (nor advised) to sign into Xcode from the
GitHub runner CI. Here's how you populate the required GitHub secrets.

**Note**: Be sure to enter these secrets for Dependabot as well, otherwise its
CI runs will fail.

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
1. **Important**: Back up the downloaded certificate into 1Password. You will no
   longer have have access to its private key (required for signing) if you lose
   it.
1. Double-click to install it in Keychain Access.
1. Right-click the cert in Keychain access. Export the certificate, choose p12
   file. Make sure to set a password -- this is the
   `APPLE_BUILD_CERTIFICATE_P12_PASSWORD`.
1. Convert the p12 file to base64:
   ```bash
   base64 < cert.p12
   ```
1. Save the base64 output as `APPLE_BUILD_CERTIFICATE_BASE64`.
1. Delete cert.p12 and the cert from Keychain Access once you're sure it's
   backed up to 1Password.

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
base64 < profile.mobileprovision
```

1. Now, you need to update the build scripts to use these. Edit
   `scripts/build/*-appstore.sh` and update the provisioning profile UUIDs. The
   UUID can be found by grepping for them in the provisioning profile files
   themselves, or just opening them in a text editor and looking halfway down
   the file. They should be the only UUIDs in the file.

## Generating new signing certificates and provisioning profiles for standalone distribution

The process is much the same as above for the macOS standalone client, with one
important difference: the signing certificate must be a Developer ID Application
certificate, not an Apple Distribution certificate. **DO NOT GENERATE A NEW
CERTIFICATE UNLESS THE OLD ONE HAS EXPIRED OR IS LOST.** Developer ID
Application certificates are **precious** and we only have a limited number of
them. They also cannot be revoked. So do not generate them. Instead, obtain it
from 1Password.

Once you've done that, you can create the provisioning profiles and update the
GitHub secrets using the same steps as above, only using the following secrets
names:

```
APPLE_STANDALONE_BUILD_CERTIFICATE_BASE64
APPLE_STANDALONE_BUILD_CERTIFICATE_P12_PASSWORD
APPLE_STANDALONE_MACOS_APP_PROVISIONING_PROFILE
APPLE_STANDALONE_MACOS_NE_PROVISIONING_PROFILE
```
