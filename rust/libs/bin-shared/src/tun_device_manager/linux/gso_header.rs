use ip_packet::{Ipv4Header, Ipv6Header, TcpHeader, UdpHeader};

/// The key by which we batch IP packets together.
///
/// We store the sequence number for TCP separately because it needs to be zero'd out initially in order to group
/// packets of the same flow to it.
#[derive(Debug, Clone, Copy, Eq)]
pub enum GsoHeader {
    Ipv4Tcp {
        ipv4: Ipv4Header,
        tcp: TcpHeader,
        original_seq: u32,
    },
    Ipv6Tcp {
        ipv6: Ipv6Header,
        tcp: TcpHeader,
        original_seq: u32,
    },
    Ipv4Udp {
        ipv4: Ipv4Header,
        udp: UdpHeader,
    },
    Ipv6Udp {
        ipv6: Ipv6Header,
        udp: UdpHeader,
    },
}

impl Ord for GsoHeader {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        match (self, other) {
            (
                GsoHeader::Ipv4Tcp {
                    ipv4: l_ipv4,
                    tcp: l_tcp,
                    ..
                },
                GsoHeader::Ipv4Tcp {
                    ipv4: r_ipv4,
                    tcp: r_tcp,
                    ..
                },
            ) => (l_ipv4, l_tcp).cmp(&(r_ipv4, r_tcp)),
            (GsoHeader::Ipv4Tcp { .. }, GsoHeader::Ipv6Tcp { .. }) => std::cmp::Ordering::Less,
            (GsoHeader::Ipv4Tcp { .. }, GsoHeader::Ipv4Udp { .. }) => std::cmp::Ordering::Less,
            (GsoHeader::Ipv4Tcp { .. }, GsoHeader::Ipv6Udp { .. }) => std::cmp::Ordering::Less,
            (GsoHeader::Ipv6Tcp { .. }, GsoHeader::Ipv4Tcp { .. }) => std::cmp::Ordering::Greater,
            (
                GsoHeader::Ipv6Tcp {
                    ipv6: l_ipv6,
                    tcp: l_tcp,
                    ..
                },
                GsoHeader::Ipv6Tcp {
                    ipv6: r_ipv6,
                    tcp: r_tcp,
                    ..
                },
            ) => (l_ipv6, l_tcp).cmp(&(r_ipv6, r_tcp)),
            (GsoHeader::Ipv6Tcp { .. }, GsoHeader::Ipv4Udp { .. }) => std::cmp::Ordering::Less,
            (GsoHeader::Ipv6Tcp { .. }, GsoHeader::Ipv6Udp { .. }) => std::cmp::Ordering::Less,
            (GsoHeader::Ipv4Udp { .. }, GsoHeader::Ipv4Tcp { .. }) => std::cmp::Ordering::Greater,
            (GsoHeader::Ipv4Udp { .. }, GsoHeader::Ipv6Tcp { .. }) => std::cmp::Ordering::Greater,
            (
                GsoHeader::Ipv4Udp {
                    ipv4: l_ipv4,
                    udp: l_udp,
                },
                GsoHeader::Ipv4Udp {
                    ipv4: r_ipv4,
                    udp: r_udp,
                },
            ) => (l_ipv4, l_udp).cmp(&(r_ipv4, r_udp)),
            (GsoHeader::Ipv4Udp { .. }, GsoHeader::Ipv6Udp { .. }) => std::cmp::Ordering::Less,
            (GsoHeader::Ipv6Udp { .. }, GsoHeader::Ipv4Tcp { .. }) => std::cmp::Ordering::Greater,
            (GsoHeader::Ipv6Udp { .. }, GsoHeader::Ipv6Tcp { .. }) => std::cmp::Ordering::Greater,
            (GsoHeader::Ipv6Udp { .. }, GsoHeader::Ipv4Udp { .. }) => std::cmp::Ordering::Greater,
            (
                GsoHeader::Ipv6Udp {
                    ipv6: l_ipv6,
                    udp: l_udp,
                },
                GsoHeader::Ipv6Udp {
                    ipv6: r_ipv6,
                    udp: r_udp,
                },
            ) => (l_ipv6, l_udp).cmp(&(r_ipv6, r_udp)),
        }
    }
}

impl PartialOrd for GsoHeader {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for GsoHeader {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (
                Self::Ipv4Tcp {
                    ipv4: l_ipv4,
                    tcp: l_tcp,
                    ..
                },
                Self::Ipv4Tcp {
                    ipv4: r_ipv4,
                    tcp: r_tcp,
                    ..
                },
            ) => l_ipv4 == r_ipv4 && l_tcp == r_tcp,
            (
                Self::Ipv6Tcp {
                    ipv6: l_ipv6,
                    tcp: l_tcp,
                    ..
                },
                Self::Ipv6Tcp {
                    ipv6: r_ipv6,
                    tcp: r_tcp,
                    ..
                },
            ) => l_ipv6 == r_ipv6 && l_tcp == r_tcp,
            (
                Self::Ipv4Udp {
                    ipv4: l_ipv4,
                    udp: l_udp,
                },
                Self::Ipv4Udp {
                    ipv4: r_ipv4,
                    udp: r_udp,
                },
            ) => l_ipv4 == r_ipv4 && l_udp == r_udp,
            (
                Self::Ipv6Udp {
                    ipv6: l_ipv6,
                    udp: l_udp,
                },
                Self::Ipv6Udp {
                    ipv6: r_ipv6,
                    udp: r_udp,
                },
            ) => l_ipv6 == r_ipv6 && l_udp == r_udp,
            _ => false,
        }
    }
}
