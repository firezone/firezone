# headless-client

This crate acts as the CLI / headless Client, and the privileged tunnel service for the GUI Client, for both Linux and Windows.

It is built as:

- `headless-client` to act as the Linux / Windows headless Client
- `firezone-headless-client` to act as the Linux tunnel service, Windows headless Client, or Windows tunnel service

In general, the brand name should be part of the file name, but the OS name should not be.

## Running

To run the headless Client:

1. Generate a new Service account token from the "Actors -> Service Accounts"
   section of the admin portal and save it in your secrets manager. The Firezone
   Linux client requires a service account at this time.
1. Ensure `/etc/dev.firezone.client/token` is only readable by root (i.e. `chmod 400`)
1. Ensure `/etc/dev.firezone.client/token` contains the Service account token. The Client needs this before it can start
1. Set `FIREZONE_ID` to a unique string to identify this client in the portal,
   e.g. `export FIREZONE_ID=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)`. The client requires this variable at
   startup. We recommend this to be a 64 character hex string.
1. Set `LOG_DIR` to a suitable directory for writing logs
   ```
   export LOG_DIR=/tmp/firezone-logs
   mkdir $LOG_DIR
   ```
1. Now, you can start the client with:

```
./firezone-headless-client standalone
```

If you're running as an unprivileged user, you'll need the `CAP_NET_ADMIN`
capability to open `/dev/net/tun`. You can add this to the client binary with:

```
sudo setcap 'cap_net_admin+eip' /path/to/firezone-headless-client
```

## X.509 device identity

The headless Client authenticates its portal connection with an MDM-provisioned
X.509 certificate over mutual TLS whenever the platform keystore holds a
currently valid certificate whose subject CN is `dev.firezone.device-trust` and
whose extended key usage permits TLS client authentication. Otherwise it
connects as it always has. Private-key bytes are never exported.

To inspect what the keystore holds without connecting to the portal or reading a
Firezone token, run:

```sh
firezone-headless-client x509
```

The command prints the matching certificates with their validity, client-auth
EKU, private-key access, signing algorithm and SHA-256 fingerprint. A keystore
without a matching identity is reported as a normal status; a keystore that
cannot be read exits non-zero.

On Linux the keystore is a PKCS#11 token, reached through p11-kit rather than
configured: the Client loads `p11-kit-proxy.so` and searches every token the
modules registered with p11-kit expose. A token that requires a PIN takes it
from `/etc/firezone/pkcs11-pin`, which must be owned by root and readable by
nobody else.

## Building

Assuming you have Rust installed, you can build the headless Client with:

```
cargo build --release -p firezone-headless-client
```

The binary will be in `target/release/firezone-headless-client`

The release on Github are built with musl. To build this way, use:

```bash
rustup target add x86_64-unknown-linux-musl
sudo apt-get install musl-tools
cargo build --release -p headless-client --target x86_64-unknown-linux-musl
```

## Files

- `/etc/dev.firezone.client/token` - The service account token, provided by the human administrator. Must be owned by root and have 600 permissions (r/w by owner, nobody else can read) If present, the tunnel will ignore any GUI Client and run as a headless Client. If absent, the tunnel will wait for commands from a GUI Client
- `/usr/bin/firezone-headless-client` - The tunnel binary. This must run as root so it can modify the system's DNS settings. If DNS is not needed, it only needs CAP_NET_ADMIN.
- `/usr/lib/systemd/system/firezone-headless-client.service` - A systemd service unit, installed by the deb package.
- `/var/lib/dev.firezone.client/config/firezone-id` - The device ID, unique across an organization. The tunnel will generate this if it's not present.
