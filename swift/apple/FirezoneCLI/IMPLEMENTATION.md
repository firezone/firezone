# Headless macOS Client Implementation: NetworkExtension Approach

## Overview

This implementation follows the NetworkExtension approach as requested, rather than the pure-Rust BSD-API approach. This provides several benefits:

1. **No root privileges required** - NetworkExtension handles TUN device creation
2. **Reuses existing code** - Leverages FirezoneKit, Store.swift, IPCClient.swift
3. **Better macOS integration** - Uses system VPN frameworks
4. **Easier deployment** - Can be distributed as a regular app
5. **API compatibility** - Matches Linux/Windows headless client API from PR #11882

## Architecture

```
┌─────────────────────────────────────────┐
│          FirezoneCLI (main.swift)       │
│  Command-line interface                 │
│  - Parse subcommands (sign-in, etc)     │
│  - Configure tunnel                     │
│  - Default action: connect              │
└─────────────┬───────────────────────────┘
              │ Uses NETunnelProviderManager
              ↓
┌─────────────────────────────────────────┐
│         FirezoneKit Library             │
│  - Store.swift (state management)       │
│  - IPCClient.swift (IPC with extension) │
│  - TunnelConfiguration                  │
│  - Token (Keychain storage)             │
└─────────────┬───────────────────────────┘
              │
              ↓
┌─────────────────────────────────────────┐
│    FirezoneNetworkExtension (existing)  │
│  - PacketTunnelProvider                 │
│  - Adapter.swift                        │
│  - Handles actual VPN tunnel            │
└─────────────────────────────────────────┘
```

## Implementation Status

### ✅ Completed

1. **CLI Source Code** (`FirezoneCLI/Sources/main.swift`)
   - **API matching PR #11882**:
     - Default behavior: Connect when run without subcommand
     - `sign-in` subcommand: Browser-based authentication
     - `sign-out` subcommand: Remove stored token
     - `version` subcommand: Show version info
   - Token management via Keychain
   - Device ID auto-generation
   - Environment variable configuration
   - Uses NETunnelProviderManager API
   - Signal handling for graceful shutdown

2. **Configuration Files**
   - `FirezoneCLI.entitlements` - App entitlements for NetworkExtension
   - `Info.plist` - Bundle information
   - `Package.swift` - Swift package manifest
   - `README.md` - Build and usage instructions
   - `IMPLEMENTATION.md` - Architecture and design documentation

3. **Documentation**
   - Architecture overview
   - Build instructions (both Xcode and command line)
   - Usage examples matching Linux/Windows API
   - Comparison with pure-Rust approach
   - API compatibility notes

### ⏳ Requires Manual Setup

The following steps require Xcode and cannot be automated:

1. **Xcode Project Configuration**
   - Add FirezoneCLI as a new target in Firezone.xcodeproj
   - Link against FirezoneKit framework
   - Configure build settings and dependencies

2. **Code Signing**
   - Configure signing certificate
   - Set up provisioning profile
   - Enable NetworkExtension capability

3. **CI/CD Integration**
   - Update `.github/workflows/_swift.yml` to build CLI target
   - Add code signing secrets
   - Configure release artifacts

## API Compatibility with PR #11882

The CLI follows the same API as Linux and Windows headless clients:

### Default Behavior
```bash
# Connect automatically (no subcommand needed)
./firezone-cli
```

### Subcommands
```bash
# Sign in interactively
./firezone-cli sign-in

# Sign out
./firezone-cli sign-out

# Show version
./firezone-cli version
```

### Environment Variables

- `FIREZONE_TOKEN` - Service account token (optional if using sign-in)
- `FIREZONE_ID` - Device identifier (auto-generated if not set)
- `FIREZONE_API_URL` - API endpoint (optional, defaults to wss://api.firezone.dev/)
- `FIREZONE_AUTH_BASE_URL` - Auth base URL for sign-in (optional)
- `FIREZONE_ACCOUNT_SLUG` - Account slug for sign-in (optional)
- `FIREZONE_NAME` - Friendly device name (optional)

## Key Differences from Pure-Rust Approach

| Aspect | NetworkExtension | Pure-Rust |
|--------|-----------------|-----------|
| Privileges | User-level | Requires root |
| TUN Device | NetworkExtension framework | BSD /dev/utun API |
| Platform | macOS only | Cross-platform |
| Distribution | App bundle with signing | Single binary |
| Codebase | Swift + Rust (via FFI) | Pure Rust |
| Deployment | Standard macOS app | Requires root setup |
| API | Same as PR #11882 | Same as PR #11882 |
| Token Storage | Keychain | File system |

## Usage Example

```bash
# Set configuration
export FIREZONE_TOKEN="ft_abc123..."
export FIREZONE_ID=$(uuidgen)
export FIREZONE_API_URL="wss://api.firezone.dev/"

# Start tunnel (runs in foreground)
./firezone-cli connect

# In another terminal, check status
./firezone-cli status

# Stop tunnel
./firezone-cli disconnect
```

## Security Considerations

1. **No root required** - Runs with user privileges
2. **NetworkExtension sandbox** - Tunnel runs in isolated extension
3. **Keychain integration** - Can store tokens securely (future enhancement)
4. **Code signing required** - Must be signed with valid Apple Developer cert

## Future Enhancements

1. **Configuration file support** - Read from ~/.config/firezone/config.toml
2. **Daemon mode** - Run as background service with launchd
3. **Log file output** - Write logs to standard location
4. **Multiple profiles** - Support switching between accounts
5. **Interactive mode** - TUI for status monitoring

## Testing

Manual testing required:

1. Build the CLI target in Xcode
2. Install NetworkExtension if not already installed
3. Run CLI with test credentials
4. Verify tunnel connects successfully
5. Test status and disconnect commands

## Related Files

- `swift/apple/FirezoneCLI/` - CLI implementation
- `swift/apple/FirezoneKit/` - Shared Swift library
- `swift/apple/FirezoneNetworkExtension/` - Network extension provider
- `rust/client-ffi/` - FFI bindings to Rust connlib

## References

- Apple NetworkExtension documentation
- WireGuard Apple implementation (for TUN FD discovery)
- Existing Firezone GUI client (for architecture patterns)
