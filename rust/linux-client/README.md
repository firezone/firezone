# linux-client

This crate houses the Firezone linux client.

## Building

Assuming you have Rust installed, you can build the Linux client from a Linux
host with:

```
cargo build --release --bin firezone-linux-client
```

You should then find a binary in `target/release/firezone-linux-client`.

The releases on Github are built with musl. To build this way, use:

```bash
rustup target add x86_64-unknown-linux-musl
sudo apt-get install musl-tools
cargo build --release --bin firezone-linux-client --target x86_64-unknown-linux-musl
```

## Running

To run the Linux client:

1. Generate a new Service account token from the "Actors -> Service Accounts"
   section of the admin portal and save it in your secrets manager. The Firezone
   Linux client requires a service account at this time.
1. Ensure the `FIREZONE_TOKEN=<service_account_token>` environment variable is
   set securely in your client's shell environment. The client requires this
   variable at startup.
1. Set `FIREZONE_ID` to a unique string to identify this client in the portal,
   e.g. `export FIREZONE_ID=$(uuidgen)`. The client requires this variable at
   startup.
1. Set `LOG_DIR` to a suitable directory for writing logs
   ```
   export LOG_DIR=/tmp/firezone-logs
   mkdir $LOG_DIR
   ```
1. Now, you can start the client with:

```
./firezone-linux-client
```

If you're running as an unprivileged user, you'll need the `CAP_NET_ADMIN`
capability to open `/dev/net/tun`. You can add this to the client binary with:

```
sudo setcap 'cap_net_admin+eip' /path/to/firezone-linux-client
```
