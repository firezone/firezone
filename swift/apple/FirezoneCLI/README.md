# Firezone CLI - NetworkExtension-based Headless Client

This is a command-line interface for Firezone that uses NetworkExtension, allowing it to run without root privileges.

## Architecture

The CLI uses the same NetworkExtension infrastructure as the GUI client:
- Reuses `FirezoneKit` for core functionality
- Uses `Store.swift` and `IPCClient.swift` for tunnel management
- Communicates with the NetworkExtension provider
- Does not require root/sudo

## Building

### Prerequisites
- Xcode 15 or later
- macOS 13 or later
- Valid Apple Developer certificate for code signing

### Adding the CLI Target to Xcode

Since this requires modifications to the Xcode project, follow these steps:

1. Open `Firezone.xcodeproj` in Xcode
2. Add a new macOS Command Line Tool target:
   - File → New → Target
   - Select "Command Line Tool" under macOS
   - Name: "FirezoneCLI"
   - Bundle Identifier: "dev.firezone.client.cli"
   - Language: Swift
   - Add to the existing project

3. Configure the target:
   - Add `FirezoneKit` as a dependency
   - Set the entitlements file: `FirezoneCLI/FirezoneCLI.entitlements`
   - Set the Info.plist: `FirezoneCLI/Info.plist`
   - Add `Sources/main.swift` as the main source file

4. Configure signing:
   - Enable "Automatically manage signing"
   - Select your development team
   - Ensure the NetworkExtension capability is enabled

5. Link against NetworkExtension:
   - Add `NetworkExtension.framework` to "Link Binary With Libraries"

### Build from Command Line

```bash
cd swift/apple
xcodebuild -project Firezone.xcodeproj \
  -scheme FirezoneCLI \
  -configuration Release \
  -derivedDataPath build \
  build
```

The binary will be in `build/Build/Products/Release/firezone-cli`

## Usage

### Environment Variables

- `FIREZONE_TOKEN` - Service account token (required)
- `FIREZONE_ID` - Device identifier (required)
- `FIREZONE_API_URL` - API URL (optional, defaults to wss://api.firezone.dev/)

### Commands

```bash
# Start the tunnel
export FIREZONE_TOKEN="your-token-here"
export FIREZONE_ID=$(uuidgen)
./firezone-cli connect

# Check status
./firezone-cli status

# Stop the tunnel
./firezone-cli disconnect

# Show version
./firezone-cli version
```

## Differences from Pure-Rust Headless Client

| Feature | NetworkExtension CLI | Pure-Rust Headless |
|---------|---------------------|-------------------|
| Root required | No | Yes |
| Platform | macOS only | Linux, Windows, macOS |
| TUN device | NetworkExtension | BSD API |
| Code signing | Required | Optional |
| Distribution | .app bundle | Single binary |
| Shared code | Uses FirezoneKit | Uses bin-shared |

## CI/CD Integration

To add this to the release process:

1. Update `.github/workflows/_swift.yml` to build the CLI target
2. Add code signing secrets for the CLI
3. Create a release artifact for the CLI binary
4. Update the release drafter configuration

## Future Work

- Add launchd plist for running as a service
- Implement proper signal handling for graceful shutdown
- Add configuration file support (not just env vars)
- Implement log file output
- Add support for multiple profiles/configurations
