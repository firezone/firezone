# Firezone Apple Client

Firezone app clients for macOS and iOS.

## Pre-requisites

- Rust

## Building

1. Clone this repo:

   ```bash
   git clone https://github.com/firezone/firezone
   ```

1. `cd` to the Apple clients code

   ```bash
   cd swift/apple
   ```

1. Rename and populate developer team ID file:

   ```bash
   cp Firezone/xcconfig/Developer.xcconfig.template Firezone/xcconfig/Developer.xcconfig
   vim Firezone/xcconfig/Developer.xcconfig
   ```

1. Open project in Xcode:

```bash
open Firezone.xcodeproj
```

Build the Firezone target

## Debugging

[This Network Extension debugging guide](https://developer.apple.com/forums/thread/725805)
is a great resource to use as a starting point.

### NetworkExtension not loading (macOS)

Try clearing your LaunchAgent db:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -delete
```

**Note**: You MUST reboot after doing this!

## Cleaning up

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
