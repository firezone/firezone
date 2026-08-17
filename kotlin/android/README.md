# Firezone Android client

This README contains instructions for building and testing the Android client
locally.

## Dev Setup

### Quick setup (recommended)

Requires [Rust](https://www.rust-lang.org/tools/install) and
[mise](https://mise.jdx.dev/getting-started.html) to be installed.

```bash
mise run setup
mise run build
```

This installs Java, Android SDK/NDK, Rust cross-compilation targets, and
creates `local.properties`. See `mise-tasks/setup.sh` for details.

To install on a connected device or emulator:

```bash
mise run install-phone     # connected hardware device
mise run install-emulator  # creates/boots an emulator and launches the app
```

Both tasks build only the cargo target matching the device's ABI (detected via
`adb` for `install-phone`, host arch for `install-emulator`), which is roughly
4x faster than the default all-ABI build.

## X.509 device identity

Firezone uses Android's system `KeyChain` for X.509 device identity. The private
key remains in the KeyChain; Firezone receives a key handle and asks it to sign
the mutual-TLS handshake. The **X.509 Device Identity** section in Advanced
Settings shows the configured alias, key access, and certificate-chain
diagnostics.

Android ownership and distribution do not create four different certificate
APIs. The important distinction is whether a device policy controller (DPC)
has granted Firezone access to a key:

| Deployment | Certificate provisioning and Firezone access | User interaction |
| --- | --- | --- |
| Personally owned, personal profile | Not supported. A work-profile DPC cannot provision private keys across the profile boundary. | Advanced Settings explains that X.509 device identity requires a managed work profile or corporate-owned device. |
| Personally owned, work profile | The DPC installs the identity in the work profile. It may pre-grant access on Android 11+, or handle the KeyChain chooser on older versions. | No prompt when pre-granted; otherwise Advanced Settings launches the system picker. |
| Corporate owned | The device/profile owner installs the identity, grants the Firezone package access, and supplies its alias as managed configuration. | None on Android 11+ when fully configured. On older releases, **Authorize Certificate** invokes the chooser so the DPC can return the alias silently. |
| AOSP | `KeyChain` is an Android framework API and does not depend on Google Play services. Managed work-profile and corporate-owned provisioning are supported when the build includes a working KeyChain service and selection UI. | Determined by whether a DPC pre-granted the key, just as on other Android builds. Unmanaged personal profiles are not supported. |

For managed deployment, set the `x509CertificateAlias` application restriction
to the exact alias used when installing the key pair. The selected leaf
certificate must have subject common name `dev.firezone.device-trust`. On
Android 11 (API 30) or newer, the DPC should also call
[`DevicePolicyManager.grantKeyPairToApp`](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#grantKeyPairToApp(android.content.ComponentName,%20java.lang.String,%20java.lang.String))
for `dev.firezone.android`. On earlier supported versions, the DPC can implement
[`onChoosePrivateKeyAlias`](https://developer.android.com/reference/android/app/admin/DeviceAdminReceiver#onChoosePrivateKeyAlias(android.content.Context,%20android.content.Intent,%20int,%20android.net.Uri,%20java.lang.String))
and return the managed alias when Firezone requests access.

An installation in a supported profile can remember an alias returned by
[`KeyChain.choosePrivateKeyAlias`](https://developer.android.com/reference/android/security/KeyChain#choosePrivateKeyAlias(android.app.Activity,%20android.security.KeyChainAliasCallback,%20java.lang.String[],%20java.security.Principal[],%20android.net.Uri,%20java.lang.String)).
If the key is removed or its grant is revoked, Advanced Settings reports it as
unavailable and the user can select it again.

The public KeyChain API intentionally resolves client identities by alias and
does not let applications enumerate every installed private-key alias. A DPC
therefore controls zero-touch selection and certificate renewal. When a SCEP
identity is renewed under the same alias, `KeyChain.getCertificateChain`
returns the current chain. If renewal creates multiple aliases, the DPC must
return the newest suitable alias from `onChoosePrivateKeyAlias`; the system
picker performs that choice for user-managed selection.

### Certificate user authentication

Firezone can connect without a saved web sign-in token when the leaf certificate
contains exactly one valid value for both of these URI SAN attributes:

- `firezone://email/<percent-encoded actor email>`
- `firezone://account-id/<Firezone account UUID>`

For example:

```text
firezone://email/alice%40example.com
firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3
```

The values may be separate URI SAN entries or part of Intune's comma-joined URI
SAN. Advanced Settings shows parsed identity attributes and all raw SAN values.
If either required attribute is missing, malformed, or ambiguous, the
certificate is still used for mutual TLS device identity and Firezone falls back
to the saved token or interactive web sign-in for user authentication.

### Wireless ADB

Useful when your USB connection is flaky. Both flows give you a regular `adb`
connection, after which `mise run install-phone` works normally.

**Android 11+** (native pairing, persists across reboots):

1. On the device: Settings → Developer options → Wireless debugging → enable.
1. Tap "Pair device with pairing code" — note the IP, port, and 6-digit code.
1. On the host:

   ```bash
   adb pair <ip>:<pair-port> <code>     # one-off pairing
   adb connect <ip>:<connect-port>      # port shown on the main wireless screen
   ```

**Android 10 and older** (USB seed required, resets on reboot):

1. Connect once over USB and confirm `adb devices` lists the phone.
1. Switch the device's adb daemon to TCP and connect:

   ```bash
   adb tcpip 5555
   adb connect <phone-ip>:5555    # Settings → About phone → Status for the IP
   ```

1. Disconnect USB. The connection persists until the phone reboots, after which
   you'll need to repeat the USB seed step.

### Manual setup

If you'd rather not use `mise run setup`:

1. Install Rust, JDK 17, and the Android SDK (via
   [Android Studio](https://developer.android.com/studio) or `sdkmanager`).
1. Install the NDK version pinned in `app/build.gradle.kts` (currently
   `28.1.13356709`) via Android Studio's SDK Manager or
   `sdkmanager "ndk;<version>"`.
1. Create `local.properties` with `sdk.dir=/path/to/Android/Sdk`.
1. Add the Rust cross-compilation targets to the toolchain pinned in
   `rust/rust-toolchain.toml`:

   ```
   rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
   ```

1. Run `./gradlew assembleDebug` to verify.

If you get errors about `rustc` or `cargo` not being found, it can help to
explicitly specify the path to these in your shell environment. For example:

```
# ~/.zprofile or ~/.bash_profile
export RUST_ANDROID_GRADLE_RUSTC_COMMAND=$HOME/.cargo/bin/rustc
export RUST_ANDROID_GRADLE_CARGO_COMMAND=$HOME/.cargo/bin/cargo
```

## Release Setup

We release from GitHub CI, so this shouldn't be necessary. But if you're looking
to test the `release` variant locally:

1. Download the keystore from 1Pass and save to `app/.signing/keystore.jks` dir.
1. Now you can execute the `*Release` tasks with:

```shell
export KEYSTORE_PATH="$(pwd)/app/.signing/keystore.jks"
HISTCONTROL=ignorespace # prevents saving the next line in shell history
 KEYSTORE_PASSWORD='keystore_password' KEYSTORE_KEY_PASSWORD='keystore_key_password' ./gradlew assembleRelease
```

## Logs

To stream colored logcat from the connected device/emulator:

```
mise run logcat
```

Set `ANDROID_SERIAL` to disambiguate when multiple devices/emulators are
connected. Pass a tag filterspec after `--` to narrow the output, e.g. just the
Rust `connlib` tag:

```
mise run logcat -- 'connlib:V *:S'
```

This will show logs of all levels from the `connlib` tag and silence logs from other tags (`*:S`).
