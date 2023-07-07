# Firezone Apple Client

Firezone app clients for macOS and iOS.

## Builidng

Clone this repo:

```bash
git clone https://github.com/firezone/firezone
```

Build Connlib:
```bash
cd rust/connlib/clients/apple
PLATFORM_NAME=macosx ./build-rust.sh # For macOS
PLATFORM_NAME=iphoneos ./build-rust.sh # For iOS
./build-xcframework-dev.sh
```

Rename and populate developer team ID file:

```bash
cp Firezone/Developer.xcconfig.template Firezone/Developer.xcconfig
vim Firezone/Developer.xcconfig
```

Open project in Xcode:

```bash
open Firezone.xcodeproj
```

Build the Firezone target
