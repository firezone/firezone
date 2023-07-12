# Firezone Apple Client

Firezone app clients for macOS and iOS.

## Pre-requisites

  - Rust

## Building

 1. Clone this repo:

    ```bash
    git clone https://github.com/firezone/firezone
    ```

 2. `cd` to the Apple clients code

    ```bash
    cd swift/apple
    ```

 3. Rename and populate developer team ID file:

    ```bash
    cp Firezone/xcconfig/Developer.xcconfig.template Firezone/xcconfig/Developer.xcconfig
    vim Firezone/xcconfig/Developer.xcconfig
    ```

 4. Open project in Xcode:

    ```bash
    open Firezone.xcodeproj
    ```

    Build the Firezone target


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
