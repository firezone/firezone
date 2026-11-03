use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Special-use IPv4 ranges the relay never sends to.
///
/// Matches `@special_use_ipv4_cidrs` in the portal's `Portal.Changeset`, except for the documentation ranges.
/// Those are not routed on the internet, and our test networks use them as public addresses.
const SPECIAL_USE_IPV4: &[(Ipv4Addr, u8)] = &[
    (Ipv4Addr::new(0, 0, 0, 0), 8),
    (Ipv4Addr::new(10, 0, 0, 0), 8),
    (Ipv4Addr::new(100, 64, 0, 0), 10),
    (Ipv4Addr::new(127, 0, 0, 0), 8),
    (Ipv4Addr::new(169, 254, 0, 0), 16),
    (Ipv4Addr::new(172, 16, 0, 0), 12),
    (Ipv4Addr::new(192, 0, 0, 0), 24),
    (Ipv4Addr::new(192, 31, 196, 0), 24),
    (Ipv4Addr::new(192, 52, 193, 0), 24),
    (Ipv4Addr::new(192, 88, 99, 0), 24),
    (Ipv4Addr::new(192, 168, 0, 0), 16),
    (Ipv4Addr::new(192, 175, 48, 0), 24),
    (Ipv4Addr::new(198, 18, 0, 0), 15),
    (Ipv4Addr::new(224, 0, 0, 0), 4),
    (Ipv4Addr::new(240, 0, 0, 0), 4),
    // Azure WireServer is a public address, so no special-use range covers it.
    (Ipv4Addr::new(168, 63, 129, 16), 32),
];

/// Special-use IPv6 ranges the relay never sends to.
///
/// Matches `@special_use_ipv6_cidrs` in the portal's `Portal.Changeset`, except for the documentation range.
/// Unlike the portal, we also refuse all IPv4-mapped addresses: an IPv6 allocation must not send IPv4 traffic.
const SPECIAL_USE_IPV6: &[(Ipv6Addr, u8)] = &[
    (Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 0), 96),
    (Ipv6Addr::new(0, 0, 0, 0, 0, 0xffff, 0, 0), 96),
    (Ipv6Addr::new(0, 0, 0, 0, 0xffff, 0, 0, 0), 96),
    (Ipv6Addr::new(0x64, 0xff9b, 0, 0, 0, 0, 0, 0), 96),
    (Ipv6Addr::new(0x64, 0xff9b, 1, 0, 0, 0, 0, 0), 48),
    (Ipv6Addr::new(0x100, 0, 0, 0, 0, 0, 0, 0), 64),
    (Ipv6Addr::new(0x2001, 0, 0, 0, 0, 0, 0, 0), 32),
    (Ipv6Addr::new(0x2001, 0x2, 0, 0, 0, 0, 0, 0), 48),
    (Ipv6Addr::new(0x2001, 0x20, 0, 0, 0, 0, 0, 0), 28),
    (Ipv6Addr::new(0x2002, 0, 0, 0, 0, 0, 0, 0), 16),
    (Ipv6Addr::new(0xfc00, 0, 0, 0, 0, 0, 0, 0), 7),
    (Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0), 10),
    (Ipv6Addr::new(0xfec0, 0, 0, 0, 0, 0, 0, 0), 10),
    (Ipv6Addr::new(0xff00, 0, 0, 0, 0, 0, 0, 0), 8),
];

/// Whether the relay may send traffic to `ip` on behalf of a client.
///
/// The relay sends from inside its own network.
/// Without this check, a client could use it to reach addresses that are not reachable from the internet,
/// such as the relay's loopback interface, its private network or the cloud metadata service.
pub(crate) fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => !SPECIAL_USE_IPV4.iter().any(|(network, prefix)| {
            let mask = u32::MAX.checked_shl(32 - u32::from(*prefix)).unwrap_or(0);

            ip.to_bits() & mask == network.to_bits() & mask
        }),
        IpAddr::V6(ip) => !SPECIAL_USE_IPV6.iter().any(|(network, prefix)| {
            let mask = u128::MAX.checked_shl(128 - u32::from(*prefix)).unwrap_or(0);

            ip.to_bits() & mask == network.to_bits() & mask
        }),
    }
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
            "169.254.0.1",
            "100.64.0.1",
            "100.127.255.255",
            "192.0.0.1",
            "192.31.196.1",
            "192.52.193.1",
            "192.88.99.1",
            "192.175.48.1",
            "198.18.0.1",
            "198.19.255.255",
            "224.0.0.1",
            "239.255.255.250",
            "240.0.0.1",
            "255.255.255.255",
            "::",
            "::1",
            "::127.0.0.1",
            "::ffff:127.0.0.1",
            "::ffff:8.8.8.8",
            "::ffff:0:169.254.169.254",
            "64:ff9b::7f00:1",
            "64:ff9b::808:808",
            "64:ff9b:1::808:808",
            "100::1",
            "2001::1",
            "2001:2::1",
            "2001:20::1",
            "2002:a9fe:a9fe::1",
            "2002:808:808::",
            "fc00::1",
            "fe80::1",
            "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "fec0::1",
            "feff::1",
            "ff02::1",
        ] {
            let ip = ip.parse::<IpAddr>().unwrap();

            assert!(!is_public(ip), "{ip} is not public");
        }
    }

    #[test]
    fn refuses_cloud_metadata_and_host_agent_addresses() {
        for ip in [
            // Azure WireServer
            "168.63.129.16",
            "::ffff:168.63.129.16",
            "64:ff9b::168.63.129.16",
            // AWS, Azure, GCP and Oracle instance metadata
            "169.254.169.254",
            // AWS DNS and time sync
            "169.254.169.253",
            "169.254.169.123",
            // AWS IMDS, DNS and time sync over IPv6
            "fd00:ec2::254",
            "fd00:ec2::253",
            "fd00:ec2::123",
            // GCP metadata over IPv6
            "fd20:ce::254",
            // Alibaba Cloud metadata
            "100.100.100.200",
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
            "168.63.129.17",
            "169.253.255.255",
            "169.255.0.0",
            "198.17.255.255",
            "198.20.0.0",
            "223.255.255.255",
            "2606:4700:4700::1111",
            "2001:4860:4860::8888",
            "2001:1::1",
            "2003::1",
        ] {
            let ip = ip.parse::<IpAddr>().unwrap();

            assert!(is_public(ip), "{ip} is public");
        }
    }

    #[test]
    fn allows_documentation_addresses() {
        for ip in ["192.0.2.1", "198.51.100.1", "203.0.113.1", "2001:db8::1"] {
            let ip = ip.parse::<IpAddr>().unwrap();

            assert!(is_public(ip), "{ip} is allowed for test networks");
        }
    }
}
