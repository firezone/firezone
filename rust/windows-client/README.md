# windows-client

This crate houses a Windows GUI client.

## Setup

This is the minimal toolchain needed to compile natively for x86_64 Windows:

1. [Install rustup](https://win.rustup.rs/x86_64) for Windows.
1. Install Tauri tooling: `cargo install tauri-cli`
1. Install [pnpm](https://pnpm.io/installation) for your platform.

### Recommended IDE Setup

(From Tauri's default README)

- [VS Code](https://code.visualstudio.com/)
- [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode)
- [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)

## Building

Builds are best started from the frontend tool `pnpm`. This ensures typescript
and css is compiled properly before bundling the application.

See the [`package.json`](./package.json) script for more details as to what's
going on under the hood.

```powershell
# Builds a release exe
pnpm build

# The release exe, MSI, and NSIS installer should be up in the workspace.
# The exe can run without being installed
stat ../target/release/firezone-windows-client.exe
stat ../target/release/bundle/msi/firezone-windows-client_0.0.0_x64_en-US.msi
stat ../target/release/bundle/nsis/firezone-windows-client_0.0.0_x64-setup.exe
```

## Running

From this dir:

```powershell
# This will start the frontend tools in watch mode and then run `tauri dev`
pnpm dev

# You can call debug subcommands on the exe from this directory too
# e.g. this is equivalent to `cargo run -- debug`
cargo tauri dev -- -- debug

# The exe is up in the workspace
stat ../target/debug/firezone-windows-client.exe
```

The app's config and logs will be stored at
`C:\Users\$USER\AppData\Local\dev.firezone.client`.

## Platform support

Tauri says it should work on Windows 10, Version 1803 and up. Older versions may
work if you
[manually install WebView2](https://tauri.app/v1/guides/getting-started/prerequisites#2-webview2)

`x86_64` architecture is supported at this time. See
[this issue](https://github.com/firezone/firezone/issues/2992) for `aarch64`
support.

## Threat model

We can split this to its own doc or generalize it to the whole project if
needed.

This is prescriptive.

The Windows client app:

- SHOULD protect against the device being stolen or tampered with, if Windows is
  locked the entire time, and if the incident is reported quick enough that the
  token can be revoked
- Cannot protect against malicious / rogue users signed in to the application
- Cannot protect against malware running with the same permissions as the user
- Cannot protect against an attacker who has physical access to a device while
  Windows is unlocked

Where the client app does protect against attackers, "protect" is defined as:

- It should be impractical to read or write the token, while Windows is locked
- It should be impractical to change the advanced settings to point to a
  malicious server, while Windows is locked

## Security as implemented

The Windows client's encrypted storage uses the
[`keyring` crate](https://crates.io/crates/keyring), which uses Windows'
credential management API.

It's hard to find good documentation on _how_ Windows encrypts these secrets,
but as I understand it:

- They are locked by a key derived from the Windows password, so if the password
  has enough entropy, and Windows is locked or shut down, the passwords are not
  trivial to exfiltrate
- They are not readable by other users on the same computer, even when Windows
  is unlocked
- They _are_ readable by any process running as the same user, while Windows is
  unlocked.

To defend against malware running with user permissions, we'd need to somehow
identify our app to Windows and tell Windows to store our token in such a way
that un-signed apps cannot read it.

Here are some sources I found while researching:

- https://www.google.com/search?hl=en&q=windows%20credential%20vault#ip=1
- https://stackoverflow.com/questions/9221245/how-do-i-store-and-retrieve-credentials-from-the-windows-vault-credential-manage
- https://security.stackexchange.com/questions/119765/how-secure-is-the-windows-credential-manager
- https://security.stackexchange.com/questions/93437/how-to-read-password-from-windows-credentials/177686#177686
  https://en.wikipedia.org/wiki/Data_Protection_API
- https://passcape.com/index.php?section=docsys&cmd=details&id=28

There are at least 2 or 3 different crypto APIs in Windows mentioned in these
pages, so not every comment applies to `keyring`. I think DPAPI is a different
API from `CredReadW` which keyring uses:
https://github.com/hwchen/keyring-rs/blob/1732b79aa31318f6dcbcc9f686ce5f054ffbb509/src/windows.rs#L204
