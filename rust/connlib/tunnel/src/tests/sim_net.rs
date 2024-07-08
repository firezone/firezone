use ip_network::{Ipv4Network, Ipv6Network};
use std::net::{Ipv4Addr, Ipv6Addr};

/// An [`Iterator`] over [`Ipv4Addr`]s used for routing packets between components within our test.
///
/// This uses the `TEST-NET-3` (`203.0.113.0/24`) address space reserved for documentation and examples in [RFC5737](https://datatracker.ietf.org/doc/html/rfc5737).
pub(crate) fn socket_ip4s() -> impl Iterator<Item = Ipv4Addr> {
    Ipv4Network::new(Ipv4Addr::new(203, 0, 113, 0), 24)
        .unwrap()
        .hosts()
}

/// An [`Iterator`] over [`Ipv6Addr`]s used for routing packets between components within our test.
///
/// This uses the `2001:DB8::/32` address space reserved for documentation and examples in [RFC3849](https://datatracker.ietf.org/doc/html/rfc3849).
pub(crate) fn socket_ip6s() -> impl Iterator<Item = Ipv6Addr> {
    Ipv6Network::new(Ipv6Addr::new(0x2001, 0xDB80, 0, 0, 0, 0, 0, 0), 32)
        .unwrap()
        .subnets_with_prefix(128)
        .map(|n| n.network_address())
}
