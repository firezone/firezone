use std::net::IpAddr;

/// Whether the relay may send traffic to `ip` on behalf of a client.
///
/// The relay sends from inside its own network.
/// Without this check, a client could use it to reach addresses that are not reachable from the internet,
/// such as the relay's loopback interface, its private network or the cloud metadata service.
pub(crate) fn is_public(ip: IpAddr) -> bool {
    !special_use_ip::is_special_use(ip)
}

/// Whether `ip` is in a private IPv4 network (RFC 1918).
pub(crate) fn is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_private(),
        IpAddr::V6(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_all_nat64_addresses() {
        for ip in ["64:ff9b::808:808", "64:ff9b::7f00:1"] {
            let ip = ip.parse::<IpAddr>().unwrap();

            assert!(!is_public(ip), "{ip} is not public");
        }
    }

    #[test]
    fn only_rfc1918_addresses_are_private() {
        for ip in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1"] {
            let ip = ip.parse::<IpAddr>().unwrap();

            assert!(is_private(ip), "{ip} is private");
        }

        for ip in [
            "127.0.0.1",
            "169.254.169.254",
            "100.64.0.1",
            "172.32.0.1",
            "::ffff:10.0.0.1",
            "fc00::1",
            "fd00:ec2::254",
            "fe80::1",
        ] {
            let ip = ip.parse::<IpAddr>().unwrap();

            assert!(!is_private(ip), "{ip} is not private");
        }
    }
}
