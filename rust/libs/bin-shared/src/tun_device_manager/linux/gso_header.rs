use ip_packet::{Ipv4Header, Ipv6Header, TcpHeader, UdpHeader};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum GsoHeader {
    Ipv4Tcp { ipv4: Ipv4Header, tcp: TcpHeader },
    Ipv6Tcp { ipv6: Ipv6Header, tcp: TcpHeader },
    Ipv4Udp { ipv4: Ipv4Header, udp: UdpHeader },
    Ipv6Udp { ipv6: Ipv6Header, udp: UdpHeader },
}
