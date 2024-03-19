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
