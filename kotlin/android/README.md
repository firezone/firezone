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
owned phone carrying a work profile: an administrator has installed a client
certificate and configured the app to use it, but only the user can grant the
app access to the key. That is the state the certificate selection screen
exists for, and it is awkward to reach on real hardware.

### Prerequisite: a DPC

Installing a key pair into the KeyChain and pushing managed configuration are
both profile-owner APIs, and neither has an `adb` equivalent, so the flow needs
a Device Policy Controller. The emulator deliberately runs an AOSP image, since
a profile owner can only be set on a user that carries no accounts, which means
there is no Play Store to install one from. Build Google's
[TestDPC](https://github.com/googlesamples/android-testdpc):

```bash
mise run //kotlin/android:work-profile:build-dpc
```

That clones and builds it under `~/.cache/firezone/android-testdpc`, which is
where `work-profile:create` looks. Set `TESTDPC_APK` to use an APK you built
elsewhere, or another DPC entirely alongside `DPC_PACKAGE` and `DPC_RECEIVER`.

### Running it

```bash
mise run work-profile:setup
```

That chains the steps below, each of which also runs on its own:

| Task                          | What it does                                                                      |
| ----------------------------- | --------------------------------------------------------------------------------- |
| `work-profile:boot`           | Creates and boots an account-free AOSP AVD                                        |
| `work-profile:create`         | Creates the managed profile and makes the DPC its profile owner                   |
| `work-profile:install-app`    | Builds the debug APK and installs it into the profile                             |
| `work-profile:certificate`    | Issues a Firezone-style client certificate with `openssl` and stages it on device |
| `work-profile:managed-config` | Names the certificate alias for the app's managed configuration                   |

The certificate carries the same `firezone://<attribute>/<value>` URI subject
alternative names a real one does, so the screen shows an actor email, an
account ID, an MDM device ID and a device serial rather than blanks. Override
`ACTOR_EMAIL`, `ACCOUNT_ID`, `MDM_DEVICE_ID`, `DEVICE_SERIAL` or `CERT_ALIAS` to
change them.

### The two manual steps

Both remaining steps live in TestDPC's UI; the tasks print numbered
instructions when they get there.

1. Install the key pair: TestDPC, "Manage certificates", "Install KeyPair",
   pick the staged `.p12`. Do **not** grant the key to the app afterwards.
   Withholding that grant is the point of the exercise.
1. Set the managed configuration: TestDPC, "Manage app restrictions",
   `dev.firezone.android`, add the string `x509CertificateAlias` with the
   certificate's alias as its value.

Signing in against a locally run portal needs more than this, because the
client only dials a non-production portal over mTLS when it is told which host
to expect (`FIREZONE_MTLS_HOST` where the client reads the environment). These
tasks stop short of that: the certificate screen appears without a reachable
portal.

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
