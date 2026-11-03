use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Azure's "WireServer": a public address that is only reachable from inside Azure VMs.
const AZURE_WIRESERVER: Ipv4Addr = Ipv4Addr::new(168, 63, 129, 16);

/// Whether the relay may send traffic to `ip` on behalf of a client.
///
/// The relay sends from inside its own network.
/// Without this check, a client could use it to reach addresses that are not reachable from the internet,
/// such as the relay's loopback interface, its private network or the cloud metadata service.
pub(crate) fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => is_public_v4(ip),
        IpAddr::V6(ip) => is_public_v6(ip),
    }
}

fn is_public_v4(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();

    let this_network = a == 0; // 0.0.0.0/8
    let shared = a == 100 && (b & 0b1100_0000) == 64; // 100.64.0.0/10 (CGNAT)
    let ietf_protocol_assignments = a == 192 && b == 0 && c == 0; // 192.0.0.0/24
    let reserved = a >= 240; // 240.0.0.0/4, includes the broadcast address

    !(this_network
        || ip.is_loopback()
        || ip.is_private()
        || ip.is_link_local() // Includes the cloud metadata service at 169.254.169.254.
        || shared
        || ietf_protocol_assignments
        || ip.is_multicast()
        || reserved
        || ip == AZURE_WIRESERVER)
}

fn is_public_v6(ip: Ipv6Addr) -> bool {
    let segments = ip.segments();

    // The relay's IPv6 sockets can also send IPv4, so we never forward to IPv4 addresses in an IPv6 wrapper.
    // This also covers `::` and `::1`.
    let ipv4_compatible = segments[..6] == [0, 0, 0, 0, 0, 0]; // ::/96
    let ipv4_mapped = ip.to_ipv4_mapped().is_some(); // ::ffff:0:0/96

    // NAT64 and 6to4 send to the embedded IPv4 address.
    let nat64 = segments[..6] == [0x64, 0xff9b, 0, 0, 0, 0]; // 64:ff9b::/96
    let nat64_local = segments[..3] == [0x64, 0xff9b, 1]; // 64:ff9b:1::/48
    let six_to_four = segments[0] == 0x2002; // 2002::/16
    let discard = segments[..4] == [0x100, 0, 0, 0]; // 100::/64
    let site_local = (segments[0] & 0xffc0) == 0xfec0; // fec0::/10

    if nat64 {
        return is_public_v4(embedded_v4(segments[6], segments[7]));
    }

    if six_to_four {
        return is_public_v4(embedded_v4(segments[1], segments[2]));
    }

    !(ipv4_compatible
        || ipv4_mapped
        || nat64_local
        || discard
        || ip.is_unique_local() // Includes the AWS metadata service at fd00:ec2::254.
        || ip.is_unicast_link_local()
        || site_local
        || ip.is_multicast())
}

fn embedded_v4(high: u16, low: u16) -> Ipv4Addr {
    Ipv4Addr::from((u32::from(high) << 16) | u32::from(low))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_non_public_addresses() {
        for ip in [
            "0.0.0.0",
            "0.1.2.3",
            "127.0.0.1",
            "127.255.255.254",
            "10.0.0.1",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.1",
            "169.254.169.254",
            "169.254.0.1",
            "100.64.0.1",
            "100.100.100.200",
            "100.127.255.255",
            "192.0.0.1",
            "224.0.0.1",
            "239.255.255.250",
            "240.0.0.1",
            "255.255.255.255",
            "168.63.129.16",
            "::",
            "::1",
            "::127.0.0.1",
            "::ffff:127.0.0.1",
            "::ffff:8.8.8.8",
            "64:ff9b::7f00:1",
            "64:ff9b::a9fe:a9fe",
            "64:ff9b:1::808:808",
            "2002:7f00:1::",
            "2002:a00:1::",
            "100::1",
            "fc00::1",
            "fd00:ec2::254",
            "fe80::1",
            "fec0::1",
            "ff02::1",
        ] {
            let ip = ip.parse::<IpAddr>().unwrap();

            assert!(!is_public(ip), "{ip} is not public");
        }
    }

    #[test]
    fn allows_public_addresses() {
        for ip in [
            "1.1.1.1",
            "8.8.8.8",
            "100.63.255.255",
            "100.128.0.0",
            "172.15.255.255",
            "172.32.0.0",
            "168.63.129.15",
            "169.253.255.255",
            "198.51.100.1",
            "203.0.113.1",
            "223.255.255.255",
            "2606:4700:4700::1111",
            "2001:4860:4860::8888",
            "64:ff9b::808:808",
            "2002:808:808::",
        ] {
            let ip = ip.parse::<IpAddr>().unwrap();

            assert!(is_public(ip), "{ip} is public");
        }
    }
}
