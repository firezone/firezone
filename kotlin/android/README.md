# Firezone Android client

This README contains instructions for building and testing the Android client
locally.

## Dev Setup

1. [Install Rust](https://www.rust-lang.org/tools/install)
1. [Install Android Studio](https://developer.android.com/studio)
1. Install your JDK 17 of choice. We recommend just
   [updating your CLI](https://stackoverflow.com/questions/43211282/using-jdk-that-is-bundled-inside-android-studio-as-java-home-on-mac)
   environment to use the JDK bundled in Android Studio to ensure you're using
   the same JDK on the CLI as Android Studio.
1. Perform a test build: `./gradlew assembleDebug`
1. [Set up a dev signing key]() and add its fingerprint to the portal's
   [`assetlinks.json`](../../elixir/apps/web/priv/static/.well-known/assetlinks.json)
   file. This is required for the App Links to successfully intercept the Auth
   redirect.
1.

# Release Setup

We release from GitHub CI, so this shouldn't be necessary. But if you're looking
to test the `release` variant locally:

1. Download the keystore from 1Pass and save to `app/.signing/keystore.jks` dir.
1. Download firebase credentials from 1Pass and save to
   `app/.signing/firebase.json`
1. Now you can execute the `*Release` tasks with:

```shell
export KEYSTORE_PATH="$(pwd)/app/.signing/keystore.jks"
export FIREBASE_CREDENTIALS_PATH="$(pwd)/app/.signing/firebase.json"
HISTCONTROL=ignorespace # prevents saving the next line in shell history
 KEYSTORE_PASSWORD='keystore_password' KEYSTORE_KEY_PASSWORD='keystore_key_password' ./gradlew assembleRelease
```
