# Firezone Apple Client

Firezone clients for macOS and iOS.

This document is intended as a reference for developers working on the Apple
clients.

## Prerequisites

1. Ensure you have the latest stable version of Xcode installed and selected.
1. Rust: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
1. Request your Firezone email added to our Apple Developer Account
1. Open Xcode, go to Settings -> Account and log in.

You may consider using a macOS VM (such as Parallels Desktop) to test the
standalone macOS client, as it can be easier to test different macOS versions
and configurations without risking your main machine.

## macOS build variants

macOS ships two builds of the same app. They differ in how the tunnel runs.

|                       | App Store                              | Standalone                                               |
| --------------------- | -------------------------------------- | -------------------------------------------------------- |
| Xcode target / scheme | `Firezone`                             | `FirezoneStandalone`                                     |
| Tunnel                | app extension, in `Contents/PlugIns`   | system extension, in `Contents/Library/SystemExtensions` |
| Tunnel entitlement    | `packet-tunnel-provider`               | `packet-tunnel-provider-systemextension`                 |
| Signed with           | Apple Distribution                     | Developer ID Application                                 |
| Shipped as            | a `.pkg` uploaded to App Store Connect | a `.dmg` and a `.pkg` attached to a GitHub release       |

The `Firezone` target also builds the iOS app. iOS has always worked the way the
macOS App Store build now does: one app, one app extension inside it.

Both builds keep the same bundle identifiers, `dev.firezone.firezone` for the
app and `dev.firezone.firezone.network-extension` for the tunnel. They are one
product shipped two ways, and only one of them can be on a Mac at a time.
Keeping the identifiers is what lets a Mac move between them and keep its
settings, its MDM configuration profile and the device id the tunnel stored. It
also means the two builds take one App ID between them, with a separate
provisioning profile each.

What the split changes when the app is running:

- An app extension only exists while the tunnel is up, and it runs as you. It
  shares the app's group container, so the app reads, clears and exports the
  tunnel's logs by reading the files itself. There is nothing to install and
  nothing for the user to approve.
- A system extension keeps running after the tunnel goes down, and it runs as
  root with its own group container. The app has to install it, ask the user to
  approve it, and talk to it over IPC to do anything with its logs.

A build cannot carry both. Apple takes only the app extension packaging on the
App Store, and only the system extension packaging for Developer ID, so two
things are standalone only:

- Serving a tunnel before anyone logs in. An app extension lives in a login
  session, and at the login window there is none.
- Using a client certificate that MDM installed at device scope. That
  certificate sits in the System keychain, and its private key needs root. A
  certificate installed at user scope works in either build.

Both of those need MDM, and MDM deploys the standalone `.pkg`, so the capability
is where it is needed.

Code that has to tell the two apart reads `BundleHelper.tunnelProviderKind`.
That comes from the `TunnelProviderKind` key every bundle declares in its
Info.plist, so the app, the tunnel and the headless client all get the same
answer.

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

`Firezone` target will orchestrate building `connlib` with Rust as an Xcode
build phase. Xcode build can be triggered both from Xcode UI or via
[mise](https://mise.jdx.dev/) tasks (see
[Development with mise](#development-with-mise) below).

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

   `macos-appstore.sh` builds the `Firezone` scheme and `macos-standalone.sh`
   builds `FirezoneStandalone`.

## Developing

### Prerequisites

It is highly recommended to temporarily
[disable SIP](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection)
in order to enable
[system extension developer mode](https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions#Enable-activation-from-any-directory).

This gives you the ability to run the whole AppBundle straight from the build
directory (e.g. via "run" button in Xcode), without needing to deploy Firezone
into /Applications directory.

PS Don't forget to re-enable SIP afterwards, as it's only needed to change the
setting, not for the developer mode itself.

### IDE

The most obvious and encouraged IDE choice for Firezone macOS/iOS development is
Xcode. It is required for:

- configuring code signing / provisioning
- performing any project-related changes (editing Xcode project manually can
  break it)
- debugging
- analyzing the app in [Instruments](#instruments)

Note: Although Swift and sourcekit-lsp are technically cross-platform, this
method still relies on Xcode to build the project. However, if you prefer to use
another IDE for code editing, you can use any LSP-compatible editor (such as
Neovim, VSCode, Zed, Emacs etc) with `sourcekit-lsp` support.

In order to configure your IDE follow these steps:

```sh
brew install xcode-build-server
mise run lsp
mise run build
```

Note: Although Swift and sourcekit-lsp are technically cross-platform, this
method still relies on Xcode to build the project.

### Development with mise

For developers who prefer command-line workflows, this project supports
[mise](https://mise.jdx.dev/) tasks as an alternative to building directly in
Xcode.

**Setup:**

Install mise: `brew install mise` or see
[mise installation docs](https://mise.jdx.dev/getting-started.html)

**Usage** (from `swift/apple/` directory):

```sh
mise tasks              # List all available tasks
mise run <task>         # Run a task (e.g. mise run build)
```

`build`, `install` and `cli` build the standalone variant, which is what most
Macs run. Set `VARIANT=appstore` to work on the other one:

```sh
VARIANT=appstore mise run build
```

From the repository root:

```sh
mise run //swift/apple:<task>   # e.g. mise run //swift/apple:build
```

### Headless client

`firezone-cli` is the macOS Client run from a terminal. It is not a separate
program: it is the app's own binary, reached through a symlink beside it at
`Firezone.app/Contents/MacOS/firezone-cli`, and it picks the command line path
when started under that name. Being the same bundle is what lets it use the VPN
configuration and system extension the app set up, which a second bundle could
not do. `mise run cli` finds it for you:

```sh
mise run cli -- --help
mise run cli -- extension status
mise run cli -- connect --account-slug my-account
```

`connect` is the default, so plain `firezone-cli` brings the tunnel up and stays
in the foreground until you stop it. `sign-out` drops the stored token.

In the standalone build it talks to the same system extension as the GUI and
will not start without it. `extension status` reports whether that extension is
installed and matches the build, and exits non-zero when it does not, so a setup
script can check before going further. It cannot install the extension, since
installing one needs a user to approve it. Launch the app once to do that.

In the App Store build there is no system extension: the tunnel ships inside the
app. `extension status` says so and always succeeds.

These environment variables are read when the matching flag is absent:

| Variable                              | Flag                           |
| ------------------------------------- | ------------------------------ |
| `FIREZONE_TOKEN`                      | none, taken from the Keychain  |
| `FIREZONE_ACCOUNT_SLUG`               | `--account-slug`               |
| `FIREZONE_API_URL`                    | `--api-url`                    |
| `FIREZONE_AUTH_BASE_URL`              | `--auth-base-url`              |
| `FIREZONE_ACTIVATE_INTERNET_RESOURCE` | `--activate-internet-resource` |
| `FIREZONE_LOG_FILTER`                 | none                           |

It never asks for a token at a prompt. The app is sandboxed, so it cannot turn
terminal echo off, and a token typed at a prompt would stay in the scrollback.
Pipe one in instead, which is what it tells you to do when it hasn't got one:

```sh
pbpaste | firezone-cli
```

Anything you don't set keeps whatever the app stored, since both share one VPN
profile. Logs go to stderr as well as to the log folder the app shares.

`connect` stops the menu bar app being kept alive, so quitting the headless
client doesn't reopen it. Launching the app puts that back.

### Instruments

`Instruments` is a powerful performance analyzer and visualizer application
developed by Apple, integrated in Xcode. It helps developers profile, debug, and
optimize their applications by tracking various metrics such as CPU activity,
memory allocation, file and network usage, graphics rendering, and energy
consumption. Instruments uses a timeline view to show events in apps like CPU
usage spikes, memory leaks, and UI responsiveness issues.

#### To profile the network extension

1. Go to Product menu -> Build For -> Profile.
1. Product -> Show Build Folder in Finder.
1. Find the built Firezone.app in `Products/Profile/Firezone.app` in the Finder
   window that opens.
1. Launch it.
1. Sign in to Firezone.
1. Open Instruments.app and attach to the running
   `dev.firezone.firezone.network-extension` process.

#### What to look for in Instruments

##### network extension memory usage

iOS has a 50 MB hard cap on memory usage in the network extension. Whenever we
make changes to our threading model it's a good idea to double-check we don't go
over there.

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

The tunnel is what writes the token, so which keychain holds it depends on the
build. The App Store build's app extension runs as you and writes to your login
keychain, which the command above reaches. The standalone build's system
extension runs as root and writes to the system keychain, so run it under `sudo`
there. Switching a Mac between the two builds leaves the token behind in the
other keychain, and the user has to sign in again.

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

## Generating new signing certificates and provisioning profiles for standalone distribution

The process is much the same as above for the macOS standalone client, with one
important difference: the signing certificate must be a Developer ID Application
certificate, not an Apple Distribution certificate. **DO NOT GENERATE A NEW
CERTIFICATE UNLESS THE OLD ONE HAS EXPIRED OR IS LOST.** Developer ID
Application certificates are **precious** and we only have a limited number of
them. They also cannot be revoked. So do not generate them. Instead, obtain it
from 1Password.

Also, the signing certificate for the package installer artifact specifically
needs to be a `Developer ID Installer` certificate, not a
`Developer ID Application` or `Apple Distribution` certificate. This is needed
to sign the PKG files we distribute that are consumed by MDMs.

Once you've done that, you can create the provisioning profiles and update the
GitHub secrets using the same steps as above, only using the following secrets
names:

```
APPLE_STANDALONE_BUILD_CERTIFICATE_BASE64
APPLE_STANDALONE_BUILD_CERTIFICATE_P12_PASSWORD
APPLE_STANDALONE_MAC_INSTALLER_CERTIFICATE_BASE64
APPLE_STANDALONE_MAC_INSTALLER_CERTIFICATE_P12_PASSWORD
APPLE_STANDALONE_MACOS_APP_PROVISIONING_PROFILE
APPLE_STANDALONE_MACOS_NE_PROVISIONING_PROFILE
```

## Code signing during development

Development builds sign themselves. `mise run build` passes
`-allowProvisioningUpdates`, so Xcode creates and downloads any profile it is
missing. If it complains that your login was rejected, sign in again under Xcode
-> Settings -> Accounts.

Release builds never do this. They are given the profiles above by UUID through
`APP_PROFILE_ID` and `NE_PROFILE_ID`, which the build scripts extract from the
secrets.
