use crate::tests::sut::TunnelTest;
use proptest::test_runner::Config;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

mod assertions;
mod reference;
mod sim_node;
mod sim_portal;
mod sim_relay;
mod strategies;
mod sut;
mod transition;

type QueryId = u16;
type IcmpSeq = u16;
type IcmpIdentifier = u16;

proptest_state_machine::prop_state_machine! {
    #![proptest_config(Config {
        cases: 1000,
        .. Config::default()
    })]

    #[test]
    fn run_tunnel_test(sequential 1..20 => TunnelTest);
}

/// The source of the packet that should be sent through the tunnel.
///
/// In normal operation, this will always be either the tunnel's IPv4 or IPv6 address.
/// A malicious client could send packets with a mangled IP but those must be dropped by gateway.
/// To test this case, we also sometimes send packest from a different IP.
#[derive(Debug, Clone, Copy)]
pub(crate) enum PacketSource {
    TunnelIp4,
    TunnelIp6,
    Other(IpAddr),
}

impl PacketSource {
    pub(crate) fn into_ip(self, tunnel_v4: Ipv4Addr, tunnel_v6: Ipv6Addr) -> IpAddr {
        match self {
            PacketSource::TunnelIp4 => tunnel_v4.into(),
            PacketSource::TunnelIp6 => tunnel_v6.into(),
            PacketSource::Other(ip) => ip,
        }
    }

    pub(crate) fn originates_from_client(&self) -> bool {
        matches!(self, PacketSource::TunnelIp4 | PacketSource::TunnelIp6)
    }

    pub(crate) fn is_v4(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp4 | PacketSource::Other(IpAddr::V4(_))
        )
    }

    pub(crate) fn is_v6(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp6 | PacketSource::Other(IpAddr::V6(_))
        )
    }
}
