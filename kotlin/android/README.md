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
1. Install the NDK version pinned as `ndkVersion` in `app/build.gradle.kts` via
   Android Studio's SDK Manager or `sdkmanager "ndk;<version>"`.
1. Create `local.properties` with `sdk.dir=/path/to/Android/Sdk`.
1. Add the Rust cross-compilation targets to the toolchain pinned in
   `rust/rust-toolchain.toml`:

   ```
   rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
   ```

1. Run `./gradlew assembleDebug` to verify.

If you get errors about `cargo` not being found, make sure `~/.cargo/bin` is on
the `PATH` of whatever launches the build; the Gradle task invokes `cargo`
directly. For example:

```
# ~/.zprofile or ~/.bash_profile
export PATH="$HOME/.cargo/bin:$PATH"
```

## Work profile test device

The `work-profile:*` tasks stand up an emulator that behaves like a personally
owned phone carrying a work profile: an administrator has configured a client
certificate, but only the user can grant the app access to the key. That is the
state the certificate selection screen exists for, and it is awkward to reach on
real hardware.

```bash
mise run //kotlin/android:work-profile:setup
```

That chains building Google's [TestDPC](https://github.com/googlesamples/android-testdpc),
booting an account-free AOSP emulator, creating the managed profile, installing
the app into it, issuing a certificate and pointing the managed configuration at
it. Each step also runs on its own; `mise tasks` lists them.

Two steps are yours, because only a profile owner can install a key pair or push
managed configuration and neither has an `adb` equivalent. The tasks print
instructions when they get there:

1. TestDPC, "Manage certificates", "Install KeyPair", pick the staged `.p12`. Do
   **not** grant the key to the app afterwards: withholding that grant is the
   point of the exercise.
1. TestDPC, "Manage app restrictions", `dev.firezone.android`, add the string
   `x509CertificateAlias` with the certificate's alias as its value.

The certificate carries the same `firezone://<attribute>/<value>` URI subject
alternative names a real one does. Override `ACTOR_EMAIL`, `ACCOUNT_ID`,
`MDM_DEVICE_ID`, `DEVICE_SERIAL`, `CERT_ALIAS` or `TESTDPC_APK` to change what it
issues.

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
