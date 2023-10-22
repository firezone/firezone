# gateway

This crate houses the Firezone gateway.

## Building

You can build the gateway using: `cargo build --release --bin firezone-gateway`

You should then find a binary in `target/release/firezone-gateway`.

## Running

To run the gateway:

```
firezone-gateway --token <token>
```

where `token` is the token shown when creating a gateway group in the Firezone
admin portal.

If you're running as an unprivileged user, you'll need the `CAP_NET_ADMIN`
capability to open `/dev/net/tun`. You can add this to the gateway binary with:

```
sudo setcap 'cap_net_admin+eip' /path/to/firezone-gateway
```

### Ports

The gateway requires no open ports. Connections automatically traverse NAT with
STUN/TURN via the [relay](../relay).
