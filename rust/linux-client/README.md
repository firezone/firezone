# linux-client

This crate houses the Firezone linux client.

## Building

You can build the linux client using:
`cargo build --release --bin firezone-linux-client`

You should then find a binary in `target/release/firezone-linux-client`.

## Running

To run the linux client:

```
firezone-linux-client --token <token>
```

where `token` is the token shown when creating a client group in the Firezone
admin portal.

If you're running as an unprivileged user, you'll need the `CAP_NET_ADMIN`
capability to open `/dev/net/tun`. You can add this to the client binary with:

```
sudo setcap 'cap_net_admin+eip' /path/to/firezone-linux-client
```
