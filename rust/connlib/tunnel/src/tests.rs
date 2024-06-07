use connlib_shared::{
    messages::{
        client::{ResourceDescriptionCidr, ResourceDescriptionDns, SiteId},
        ClientId, DnsServer, GatewayId, RelayId, ResourceId,
    },
    DomainName,
};
use hickory_proto::rr::RecordType;
use ip_network_table::IpNetworkTable;
use proptest::{sample, test_runner::Config};
use std::{
    collections::{HashMap, HashSet},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    str::FromStr,
};

mod assertions;
mod reference;
mod sim_node;
mod sim_relay;
mod strategies;
mod sut;

use assertions::*;
use reference::*;
use sim_node::*;
use sim_relay::*;
use sut::*;

proptest_state_machine::prop_state_machine! {
    #![proptest_config(Config {
        cases: 1000,
        .. Config::default()
    })]

    #[test]
    fn run_tunnel_test(sequential 1..20 => TunnelTest);
}

type QueryId = u16;
type IcmpSeq = u16;
type IcmpIdentifier = u16;

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
pub(crate) enum Transition {
    /// Add a new CIDR resource to the client.
    AddCidrResource(ResourceDescriptionCidr),
    /// Send an ICMP packet to non-resource IP.
    SendICMPPacketToNonResourceIp {
        dst: IpAddr,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to an IP we resolved via DNS but is not a resource.
    SendICMPPacketToResolvedNonResourceIp {
        idx: sample::Index,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to a resource.
    SendICMPPacketToResource {
        idx: sample::Index,
        seq: u16,
        identifier: u16,
        src: PacketSource,
    },

    /// Add a new DNS resource to the client.
    AddDnsResource {
        resource: ResourceDescriptionDns,
        /// The DNS records to add together with the resource.
        records: HashMap<DomainName, HashSet<IpAddr>>,
    },
    /// Send a DNS query.
    SendDnsQuery {
        /// The index into the list of global DNS names (includes all DNS resources).
        r_idx: sample::Index,
        /// The type of DNS query we should send.
        r_type: RecordType,
        /// The DNS query ID.
        query_id: u16,
        /// The index into our list of DNS servers.
        dns_server_idx: sample::Index,
    },

    /// The system's DNS servers changed.
    UpdateSystemDnsServers { servers: Vec<IpAddr> },
    /// The upstream DNS servers changed.
    UpdateUpstreamDnsServers { servers: Vec<DnsServer> },

    /// Advance time by this many milliseconds.
    Tick { millis: u64 },
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
    fn into_ip(self, tunnel_v4: Ipv4Addr, tunnel_v6: Ipv6Addr) -> IpAddr {
        match self {
            PacketSource::TunnelIp4 => tunnel_v4.into(),
            PacketSource::TunnelIp6 => tunnel_v6.into(),
            PacketSource::Other(ip) => ip,
        }
    }

    fn originates_from_client(&self) -> bool {
        matches!(self, PacketSource::TunnelIp4 | PacketSource::TunnelIp6)
    }

    fn is_ipv4(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp4 | PacketSource::Other(IpAddr::V4(_))
        )
    }

    fn is_ipv6(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp6 | PacketSource::Other(IpAddr::V6(_))
        )
    }
}

#[derive(Debug, Clone)]
enum ResourceDst {
    Cidr(IpAddr),
    Dns(DomainName),
}

impl ResourceDst {
    /// Translates a randomly sampled [`ResourceDst`] into the [`IpAddr`] to be used for the packet.
    ///
    /// For CIDR resources, we use the IP directly.
    /// For DNS resources, we need to pick any of the proxy IPs that connlib gave us for the domain name.
    fn into_actual_packet_dst(
        self,
        idx: sample::Index,
        src: PacketSource,
        client_dns_records: &HashMap<DomainName, Vec<IpAddr>>,
    ) -> IpAddr {
        match self {
            ResourceDst::Cidr(ip) => ip,
            ResourceDst::Dns(domain) => {
                let mut ips = client_dns_records
                    .get(&domain)
                    .expect("DNS records to contain domain name")
                    .clone();

                ips.retain(|ip| ip.is_ipv4() == src.is_ipv4());

                *idx.get(&ips)
            }
        }
    }
}

/// Stub implementation of the portal.
///
/// Currently, we only simulate a connection between a single client and a single gateway on a single site.
#[derive(Debug, Clone)]
struct SimPortal {
    _client: ClientId,
    gateway: GatewayId,
    _relay: RelayId,
}

impl SimPortal {
    /// Picks, which gateway and site we should connect to for the given resource.
    fn handle_connection_intent(
        &self,
        resource: ResourceId,
        _connected_gateway_ids: HashSet<GatewayId>,
        client_cidr_resources: &IpNetworkTable<ResourceDescriptionCidr>,
        client_dns_resources: &HashMap<ResourceId, ResourceDescriptionDns>,
    ) -> (GatewayId, SiteId) {
        // TODO: Should we somehow vary how many gateways we connect to?
        // TODO: Should we somehow pick, which site to use?

        let cidr_site = client_cidr_resources
            .iter()
            .find_map(|(_, r)| (r.id == resource).then_some(r.sites.first()?.id));

        let dns_site = client_dns_resources
            .get(&resource)
            .and_then(|r| Some(r.sites.first()?.id));

        (
            self.gateway,
            cidr_site
                .or(dns_site)
                .expect("resource to be a known CIDR or DNS resource"),
        )
    }
}

#[derive(Clone, Copy, PartialEq)]
struct PrivateKey([u8; 32]);

impl fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("PrivateKey")
            .field(&hex::encode(self.0))
            .finish()
    }
}

fn hickory_name_to_domain(mut name: hickory_proto::rr::Name) -> DomainName {
    name.set_fqdn(false); // Hack to work around hickory always parsing as FQ
    let name = name.to_string();

    let domain = DomainName::from_chars(name.chars()).unwrap();
    debug_assert_eq!(name, domain.to_string());

    domain
}

fn domain_to_hickory_name(domain: DomainName) -> hickory_proto::rr::Name {
    let domain = domain.to_string();

    let name = hickory_proto::rr::Name::from_str(&domain).unwrap();
    debug_assert_eq!(name.to_string(), domain);

    name
}
