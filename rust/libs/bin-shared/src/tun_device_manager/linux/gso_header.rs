use ip_packet::{Ipv4Header, Ipv6Header, TcpHeader, UdpHeader};

/// The key by which we batch IP packets together.
///
/// We store the sequence number for TCP separately because it needs to be zero'd out initially in order to group
/// packets of the same flow to it.
#[derive(Debug, Clone, Eq, PartialOrd, Ord)]
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ipv4_tcp_original_seq_not_in_eq() {
        let header1 = GsoHeader::Ipv4Tcp {
            ipv4: Ipv4Header::default(),
            tcp: TcpHeader::default(),
            original_seq: 100,
        };
        let header2 = GsoHeader::Ipv4Tcp {
            ipv4: Ipv4Header::default(),
            tcp: TcpHeader::default(),
            original_seq: 200,
        };
        assert_eq!(header1, header2);
    }

    #[test]
    fn test_ipv6_tcp_original_seq_not_in_eq() {
        let header1 = GsoHeader::Ipv6Tcp {
            ipv6: Ipv6Header::default(),
            tcp: TcpHeader::default(),
            original_seq: 100,
        };
        let header2 = GsoHeader::Ipv6Tcp {
            ipv6: Ipv6Header::default(),
            tcp: TcpHeader::default(),
            original_seq: 200,
        };
        assert_eq!(header1, header2);
    }
}
