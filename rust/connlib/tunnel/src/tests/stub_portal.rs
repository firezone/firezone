use super::{
    dns_records::DnsRecords,
    sim_client::{ref_client_host, RefClient},
    sim_gateway::{ref_gateway_host, RefGateway},
    sim_net::Host,
    strategies::{resolved_ips, subdomain_records},
};
use crate::messages::gateway::{Filter, Filters};
use crate::messages::{gateway, DnsServer};
use crate::proptest::*;
use connlib_model::{GatewayId, Site};
use connlib_model::{ResourceId, SiteId};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_packet::Protocol;
use itertools::Itertools;
use proptest::{
    sample::Selector,
    strategy::{Just, Strategy},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

/// Full model of a resource, resembling what the portal stores, projections of this are sent to the client and gateways
#[derive(Debug, Clone)]
pub(crate) enum Resource {
    Cidr(CidrResource),
    Dns(DnsResource),
    Internet(InternetResource),
}

impl Resource {
    pub(crate) fn id(&self) -> ResourceId {
        match self {
            Resource::Cidr(r) => r.id,
            Resource::Dns(r) => r.id,
            Resource::Internet(r) => r.id,
        }
    }

    pub(crate) fn filters(&self) -> Filters {
        match self {
            Resource::Cidr(r) => r.filters.clone(),
            Resource::Dns(r) => r.filters.clone(),
            Resource::Internet(_) => vec![],
        }
    }
}

/// Full model of an Internet resource, resembling what the portal stores, projections of this are sent to the client and gateways
#[derive(Debug, Clone)]
pub(crate) struct InternetResource {
    pub name: String,
    pub id: ResourceId,
    pub sites: Vec<Site>,
}

/// Full model of a DNS resource, resembling what the portal stores, projections of this are sent to the client and gateways
#[derive(Debug, Clone, PartialEq, Eq, derivative::Derivative)]
#[derivative(PartialOrd, Ord)]
pub(crate) struct DnsResource {
    pub id: ResourceId,
    pub address: String,
    pub name: String,
    #[derivative(PartialOrd = "ignore")]
    #[derivative(Ord = "ignore")]
    pub filters: Filters,
    pub sites: Vec<Site>,
    pub address_description: Option<String>,
}

/// Full model of a CIDR resource, ressembling what the portal stores, proyections of this are sent to the client and gateways
#[derive(Debug, Clone, PartialEq, Eq, derivative::Derivative)]
#[derivative(PartialOrd, Ord)]
pub(crate) struct CidrResource {
    pub id: ResourceId,
    pub address: IpNetwork,
    pub name: String,
    #[derivative(PartialOrd = "ignore")]
    #[derivative(Ord = "ignore")]
    pub filters: Filters,
    pub sites: Vec<Site>,
    pub address_description: Option<String>,
}

impl CidrResource {
    pub(crate) fn is_allowed(&self, p: &Protocol) -> bool {
        filters_allow(&self.filters, p)
    }
}

impl DnsResource {
    pub(crate) fn is_allowed(&self, p: &Protocol) -> bool {
        filters_allow(&self.filters, p)
    }
}

impl From<Resource> for crate::client::Resource {
    fn from(value: Resource) -> Self {
        match value {
            Resource::Cidr(r) => crate::client::Resource::Cidr(r.into()),
            Resource::Dns(r) => crate::client::Resource::Dns(r.into()),
            Resource::Internet(r) => crate::client::Resource::Internet(r.into()),
        }
    }
}

impl From<InternetResource> for crate::client::InternetResource {
    fn from(value: InternetResource) -> Self {
        Self {
            name: value.name,
            id: value.id,
            sites: value.sites,
        }
    }
}

impl From<CidrResource> for crate::client::CidrResource {
    fn from(value: CidrResource) -> Self {
        Self {
            id: value.id,
            address: value.address,
            name: value.name,
            address_description: value.address_description,
            sites: value.sites,
        }
    }
}

impl From<DnsResource> for crate::client::DnsResource {
    fn from(value: DnsResource) -> Self {
        Self {
            id: value.id,
            address: value.address,
            name: value.name,
            address_description: value.address_description,
            sites: value.sites,
        }
    }
}

impl From<CidrResource> for crate::messages::gateway::ResourceDescriptionCidr {
    fn from(value: CidrResource) -> Self {
        Self {
            id: value.id,
            address: value.address,
            name: value.name,
            filters: value.filters,
        }
    }
}

impl From<DnsResource> for crate::messages::gateway::ResourceDescriptionDns {
    fn from(value: DnsResource) -> Self {
        Self {
            id: value.id,
            address: value.address,
            name: value.name,
            filters: value.filters,
        }
    }
}

/// Stub implementation of the portal.
#[derive(Clone, derivative::Derivative)]
#[derivative(Debug)]
pub(crate) struct StubPortal {
    gateways_by_site: BTreeMap<SiteId, BTreeSet<GatewayId>>,

    #[derivative(Debug = "ignore")]
    sites_by_resource: BTreeMap<ResourceId, SiteId>,

    cidr_resources: BTreeMap<ResourceId, CidrResource>,
    dns_resources: BTreeMap<ResourceId, DnsResource>,
    internet_resource: InternetResource,

    #[derivative(Debug = "ignore")]
    gateway_selector: Selector,
}

impl StubPortal {
    pub(crate) fn new(
        gateways_by_site: BTreeMap<SiteId, BTreeSet<GatewayId>>,
        gateway_selector: Selector,
        cidr_resources: BTreeSet<CidrResource>,
        dns_resources: BTreeSet<DnsResource>,
        internet_resource: InternetResource,
    ) -> Self {
        let cidr_resources = cidr_resources
            .into_iter()
            .map(|r| (r.id, r))
            .collect::<BTreeMap<_, _>>();
        let dns_resources = dns_resources
            .into_iter()
            .map(|r| (r.id, r))
            .collect::<BTreeMap<_, _>>();

        let cidr_sites = cidr_resources.iter().map(|(id, r)| {
            (
                *id,
                r.sites
                    .iter()
                    .exactly_one()
                    .expect("only single-site resources")
                    .id,
            )
        });
        let dns_sites = dns_resources.iter().map(|(id, r)| {
            (
                *id,
                r.sites
                    .iter()
                    .exactly_one()
                    .expect("only single-site resources")
                    .id,
            )
        });
        let internet_site = iter::once((
            internet_resource.id,
            internet_resource
                .sites
                .iter()
                .exactly_one()
                .expect("only single-site resources")
                .id,
        ));

        Self {
            gateways_by_site,
            gateway_selector,
            sites_by_resource: BTreeMap::from_iter(
                cidr_sites.chain(dns_sites).chain(internet_site),
            ),
            cidr_resources,
            dns_resources,
            internet_resource,
        }
    }

    pub(crate) fn all_resources(&self) -> Vec<Resource> {
        self.cidr_resources
            .values()
            .cloned()
            .map_into()
            .map(Resource::Cidr)
            .chain(self.dns_resources.values().cloned().map(Resource::Dns))
            .chain(iter::once(self.internet_resource.clone()).map(Resource::Internet))
            .collect()
    }

    /// Picks, which gateway and site we should connect to for the given resource.
    pub(crate) fn handle_connection_intent(
        &self,
        resource: ResourceId,
        _connected_gateway_ids: BTreeSet<GatewayId>,
    ) -> (GatewayId, SiteId) {
        let site_id = self
            .sites_by_resource
            .get(&resource)
            .expect("resource to be known");

        let gateways = self.gateways_by_site.get(site_id).unwrap();
        let gateway = self.gateway_selector.select(gateways);

        (*gateway, *site_id)
    }

    pub(crate) fn map_portal_resource_to_gateway_resource(
        &self,
        resource_id: ResourceId,
    ) -> gateway::ResourceDescription {
        let cidr_resource = self.cidr_resources.iter().find_map(|(_, r)| {
            (r.id == resource_id).then_some(gateway::ResourceDescription::Cidr(
                gateway::ResourceDescriptionCidr::from(r.clone()),
            ))
        });

        let dns_resource = self.dns_resources.get(&resource_id).and_then(|r| {
            (r.id == resource_id).then_some(gateway::ResourceDescription::Dns(
                gateway::ResourceDescriptionDns::from(r.clone()),
            ))
        });

        let internet_resource = Some(gateway::ResourceDescription::Internet(
            gateway::ResourceDescriptionInternet {
                id: self.internet_resource.id,
            },
        ));

        cidr_resource
            .or(dns_resource)
            .or(internet_resource)
            .expect("resource to be a known CIDR, DNS or Internet resource")
    }

    pub(crate) fn gateway_for_resource(&self, rid: ResourceId) -> Option<&GatewayId> {
        let cidr_site = self
            .cidr_resources
            .iter()
            .find_map(|(_, r)| (r.id == rid).then_some(r.sites.first()?.id));

        let dns_site = self
            .dns_resources
            .get(&rid)
            .and_then(|r| Some(r.sites.first()?.id));

        let internet_site = (self.internet_resource.id == rid)
            .then(|| Some(self.internet_resource.sites.first()?.id))
            .flatten();

        let sid = cidr_site.or(dns_site).or(internet_site)?;
        let gateways = self.gateways_by_site.get(&sid)?;
        let gid = self.gateway_selector.try_select(gateways)?;

        Some(gid)
    }

    pub(crate) fn gateways(&self) -> impl Strategy<Value = BTreeMap<GatewayId, Host<RefGateway>>> {
        self.gateways_by_site
            .values()
            .flatten()
            .map(|gid| (Just(*gid), ref_gateway_host())) // Map each ID to a strategy that samples a gateway.
            .collect::<Vec<_>>() // A `Vec<Strategy>` implements `Strategy<Value = Vec<_>>`
            .prop_map(BTreeMap::from_iter)
    }

    pub(crate) fn client(
        &self,
        system_dns: impl Strategy<Value = Vec<IpAddr>>,
        upstream_dns: impl Strategy<Value = Vec<DnsServer>>,
    ) -> impl Strategy<Value = Host<RefClient>> {
        let client_tunnel_ip4 = tunnel_ip4s().next().unwrap();
        let client_tunnel_ip6 = tunnel_ip6s().next().unwrap();

        ref_client_host(
            Just(client_tunnel_ip4),
            Just(client_tunnel_ip6),
            system_dns,
            upstream_dns,
        )
    }

    pub(crate) fn dns_resource_records(&self) -> impl Strategy<Value = DnsRecords> {
        self.dns_resources
            .values()
            .map(|resource| {
                let address = resource.address.clone();

                // Only generate simple wildcard domains for these tests.
                // The matching logic is extensively unit-tested so we don't need to cover all cases here.
                // What we do want to cover is multiple domains pointing to the same resource.
                // For example, `*.example.com` and `app.example.com`.
                match address.split_once('.') {
                    Some(("*" | "**", base)) => {
                        subdomain_records(base.to_owned(), domain_label()).boxed()
                    }
                    _ => resolved_ips()
                        .prop_map(move |resolved_ips| {
                            DnsRecords::from([(address.parse().unwrap(), resolved_ips)])
                        })
                        .boxed(),
                }
            })
            .collect::<Vec<_>>()
            .prop_map(|records| {
                let mut map = DnsRecords::default();

                for record in records {
                    map.merge(record)
                }

                map
            })
    }

    pub(crate) fn resource_by_id(&self, rid: &ResourceId) -> Option<Resource> {
        let cidr_resource = self.cidr_resources.get(rid).cloned().map(Resource::Cidr);

        let dns_resource = self.dns_resources.get(rid).cloned().map(Resource::Dns);

        let internet_resource = (&self.internet_resource.id == rid)
            .then_some(self.internet_resource.clone())
            .map(Resource::Internet);

        cidr_resource.or(dns_resource).or(internet_resource)
    }
}

const IPV4_TUNNEL: Ipv4Network = match Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};
const IPV6_TUNNEL: Ipv6Network =
    match Ipv6Network::new(Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0), 107) {
        Ok(n) => n,
        Err(_) => unreachable!(),
    };

pub fn dns_resource(sites: impl Strategy<Value = Vec<Site>>) -> impl Strategy<Value = DnsResource> {
    (
        resource_id(),
        resource_name(),
        domain_name(2..4),
        address_description(),
        filters(),
        sites,
    )
        .prop_map(
            move |(id, name, address, address_description, filters, sites)| DnsResource {
                id,
                address,
                name,
                sites,
                address_description,
                filters,
            },
        )
}

pub fn cidr_resource(
    ip_network: impl Strategy<Value = IpNetwork>,
    sites: impl Strategy<Value = Vec<Site>>,
) -> impl Strategy<Value = CidrResource> {
    (
        resource_id(),
        resource_name(),
        ip_network,
        address_description(),
        filters(),
        sites,
    )
        .prop_map(
            move |(id, name, address, address_description, filters, sites)| CidrResource {
                id,
                address,
                name,
                sites,
                address_description,
                filters,
            },
        )
}

pub fn internet_resource(
    sites: impl Strategy<Value = Vec<Site>>,
) -> impl Strategy<Value = InternetResource> {
    (resource_id(), sites).prop_map(move |(id, sites)| InternetResource {
        name: "Internet Resource".to_string(),
        id,
        sites,
    })
}

fn filters_allow(filters: &Filters, protocol: &Protocol) -> bool {
    if filters.is_empty() {
        return true;
    }

    filters.iter().any(|f| filter_contains(f, protocol))
}

fn filter_contains(filter: &Filter, protocol: &Protocol) -> bool {
    let (port_range, dst) = match (filter, protocol) {
        (Filter::Udp(port_range), Protocol::Udp(dst)) => (*port_range, *dst),
        (Filter::Tcp(port_range), Protocol::Tcp(dst)) => (*port_range, *dst),
        (Filter::Icmp, Protocol::Icmp(_)) => {
            return true;
        }
        _ => {
            return false;
        }
    };

    port_range.port_range_start <= dst && dst <= port_range.port_range_end
}

/// An [`Iterator`] over the possible IPv4 addresses of a tunnel interface.
///
/// We use the CG-NAT range for IPv4.
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L7>.
fn tunnel_ip4s() -> impl Iterator<Item = Ipv4Addr> {
    IPV4_TUNNEL.hosts()
}

/// An [`Iterator`] over the possible IPv6 addresses of a tunnel interface.
///
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L8>.
fn tunnel_ip6s() -> impl Iterator<Item = Ipv6Addr> {
    IPV6_TUNNEL
        .subnets_with_prefix(128)
        .map(|n| n.network_address())
}
