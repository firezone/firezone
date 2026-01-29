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

The CLI follows the same API as Linux and Windows headless clients from PR #11882.

### Default Behavior (Connect)

When run without any subcommand, `firezone-cli` automatically connects to Firezone:

```bash
# Connect using stored token from sign-in
./firezone-cli

# Or connect using environment variable
export FIREZONE_TOKEN="your-token-here"
./firezone-cli
```

### Subcommands

#### sign-in

Interactive browser-based authentication:

```bash
# Sign in with default settings
./firezone-cli sign-in

# Sign in with custom auth URL and account
export FIREZONE_AUTH_BASE_URL="https://app.firezone.dev"
export FIREZONE_ACCOUNT_SLUG="my-account"
./firezone-cli sign-in
```

This will:
1. Display a URL to open in your browser
2. Wait for you to complete authentication
3. Prompt you to paste the token
4. Store the token securely in Keychain

#### sign-out

Remove stored authentication token:

```bash
./firezone-cli sign-out
```

#### version

Show version information:

```bash
./firezone-cli version
```

### Environment Variables

- `FIREZONE_TOKEN` - Service account token (optional if using sign-in)
- `FIREZONE_ID` - Device identifier (auto-generated if not set)
- `FIREZONE_API_URL` - API URL (optional, defaults to wss://api.firezone.dev/)
- `FIREZONE_AUTH_BASE_URL` - Auth base URL for sign-in (optional, defaults to https://app.firezone.dev)
- `FIREZONE_ACCOUNT_SLUG` - Account slug for sign-in (optional)
- `FIREZONE_NAME` - Friendly name for this device (optional)

### Examples

```bash
# First-time setup with browser authentication
./firezone-cli sign-in

# Connect after sign-in
./firezone-cli

# Connect with environment variables (no sign-in needed)
export FIREZONE_TOKEN="your-service-account-token"
export FIREZONE_ID=$(uuidgen)
./firezone-cli

# Sign out when done
./firezone-cli sign-out
```

## API Compatibility

This implementation matches the API introduced in PR #11882 for Linux and Windows headless clients:

- **Default action**: Connect (no explicit "connect" command needed)
- **sign-in**: Browser-based interactive authentication
- **sign-out**: Remove stored token
- **Implied disconnect**: Stop the CLI process (Ctrl+C) to disconnect

## Differences from Pure-Rust Headless Client

| Feature | NetworkExtension CLI | Pure-Rust Headless |
|---------|---------------------|-------------------|
| Root required | No | Yes |
| Platform | macOS only | Linux, Windows, macOS |
| TUN device | NetworkExtension | BSD API |
| Code signing | Required | Optional |
| Distribution | .app bundle | Single binary |
| Shared code | Uses FirezoneKit | Uses bin-shared |
| API | Same as PR #11882 | Same as PR #11882 |

## CI/CD Integration

To add this to the release process:

1. Update `.github/workflows/_swift.yml` to build the CLI target
2. Add code signing secrets for the CLI
3. Create a release artifact for the CLI binary
4. Update the release drafter configuration

## Future Work

- Add launchd plist for running as a service
- Implement log file output
- Add support for multiple profiles/configurations
- Add status command to show tunnel state

