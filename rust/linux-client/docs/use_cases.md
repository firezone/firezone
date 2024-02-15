# Linux client use cases

This document lists the most common use cases that we could test. Exhaustively
tesing everything would be difficult. These cases at least exercise every
feature once, although they don't exercise every combination of features.

1. Alpine Docker container, CLI only, resolv.conf DNS (Easy to test)
2. Exe only, Manual startup, CLI only, No DNS (Embedded / IoT)
3. Exe only, Manual startup, CLI only, resolv.conf DNS (Embedded / IoT)
4. Package manager installation, runs as always-on systemd service unit, Tauri GUI, resolvectl DNS (A desktop that doesn't have NetworkManager)
5. Package manager installation, runs as systemd service unit, activated by NetworkManager, Tauri GUI and NetworkManager interfaces, NetworkManager DNS (The "Make me one with everything" option)

If we don't test a real package manager (e.g. apt, yum) we can consider
a tarball artifact to be a "package" and untar it in CI to get the systemd and NetworkManager service files. `cargo-deb` does work well for Debian systems.

## Code paths to be exercised

### Install method

1. Exe only
2. Package manager (e.g. apt / yum) or equivalent manual install
3. Docker (Unsupported in prod, only for testing?)

### Startup

1. Manual
2. Systemd service unit
3. D-Bus service activation by NetworkManager

### Interface

1. CLI only
2. Tauri GUI
3. NetworkManager plugin

### DNS control method

1. None
2. resolv.conf
3. resolvectl
4. NetworkManager
