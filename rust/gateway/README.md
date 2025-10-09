# gateway

This crate houses the Firezone gateway.

## Building

You can build the gateway using: `cargo build --release --bin firezone-gateway`

You should then find a binary in `target/release/firezone-gateway`.

## Running

The Firezone Gateway supports Linux only. To run the Gateway binary on your
Linux host:

1. Generate a new Gateway token from the "Gateways" section of the admin portal
   and save it in your secrets manager.
1. Provide the token to the Gateway using one of these methods:
   - Set the `FIREZONE_TOKEN=<gateway_token>` environment variable
   - Set a [systemd credentials](https://systemd.io/CREDENTIALS) named `FIREZONE_TOKEN`.
1. Set `FIREZONE_ID` to a unique string to identify this gateway in the portal,
   e.g. `export FIREZONE_ID=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)`. The Gateway requires this variable at
   startup. We recommend this to be a 64 character hex string.
1. Now, you can start the Gateway with:

```
firezone-gateway
```

If you're running as a non-root user, you'll need the `CAP_NET_ADMIN` capability
to open `/dev/net/tun`. You can add this to the gateway binary with:

```
sudo setcap 'cap_net_admin+eip' /path/to/firezone-gateway
```

### Ports

The gateway requires no open ports. Connections automatically traverse NAT with
STUN/TURN via the [relay](../relay).
