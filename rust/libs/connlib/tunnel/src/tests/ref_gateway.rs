use super::{
    dns_records::DnsRecords,
    reference::{PrivateKey, private_key},
    sim_gateway::SimGateway,
    sim_net::{Host, dual_ip_stack, host},
    strategies::latency,
};
use crate::{GatewayState, IpConfig};
use chrono::{DateTime, Utc};
use connlib_model::GatewayId;
use proptest::prelude::*;
use std::{
    collections::BTreeSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Instant,
};

/// Reference state for a particular gateway.
#[derive(Debug, Clone)]
pub struct RefGateway {
    pub(crate) key: PrivateKey,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,

    site_specific_dns_records: DnsRecords,
}

impl RefGateway {
    /// Initialize the [`GatewayState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(
        self,
        id: GatewayId,
        tcp_resources: BTreeSet<SocketAddr>,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) -> SimGateway {
        let mut sut = GatewayState::new(
            false,
            self.key.0,
            now,
            utc_now
                .signed_duration_since(DateTime::UNIX_EPOCH)
                .to_std()
                .unwrap(),
        ); // Cheating a bit here by reusing the key as seed.
        sut.update_tun_device(IpConfig {
            v4: self.tunnel_ip4,
            v6: self.tunnel_ip6,
        });

        SimGateway::new(id, sut, tcp_resources, self.site_specific_dns_records, now)
    }

    pub(crate) fn tunnel_ip_for(&self, dst: IpAddr) -> IpAddr {
        match dst {
            IpAddr::V4(_) => self.tunnel_ip4.into(),
            IpAddr::V6(_) => self.tunnel_ip6.into(),
        }
    }

    pub fn dns_records(&self) -> &DnsRecords {
        &self.site_specific_dns_records
    }
}

pub(crate) fn ref_gateway_host(
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
    site_specific_dns_records: impl Strategy<Value = DnsRecords>,
) -> impl Strategy<Value = Host<RefGateway>> {
    host(
        dual_ip_stack(),
        Just(52625),
        ref_gateway(tunnel_ip4s, tunnel_ip6s, site_specific_dns_records),
        latency(200), // We assume gateways have a somewhat decent Internet connection.
    )
}

fn ref_gateway(
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
    site_specific_dns_records: impl Strategy<Value = DnsRecords>,
) -> impl Strategy<Value = RefGateway> {
    (
        private_key(),
        tunnel_ip4s,
        tunnel_ip6s,
        site_specific_dns_records,
    )
        .prop_map(
            move |(key, tunnel_ip4, tunnel_ip6, site_specific_dns_records)| RefGateway {
                key,
                tunnel_ip4,
                tunnel_ip6,
                site_specific_dns_records,
            },
        )
}
