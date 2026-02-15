use super::{
    dns_records::DnsRecords,
    sim_client::{RefClient, ref_client_host},
    sim_gateway::{RefGateway, ref_gateway_host},
    sim_net::Host,
    strategies::{resolved_ips, site_specific_dns_record, subdomain_records},
};
use crate::{
    client,
    messages::{UpstreamDo53, UpstreamDoH},
    proptest::*,
};
use crate::{client::DnsResource, messages::gateway};
use connlib_model::{GatewayId, Site};
use connlib_model::{ResourceId, SiteId};
use dns_types::DomainName;
use ip_network::IpNetwork;
use itertools::Itertools;
use proptest::{
    collection,
    sample::{self, Selector},
    strategy::{Just, Strategy},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::Instant,
};

/// Stub implementation of the portal.
#[derive(Clone, derive_more::Debug)]
pub(crate) struct StubPortal {
    client_tunnel_ipv4: Ipv4Addr,
    client_tunnel_ipv6: Ipv6Addr,

    gateways_by_site: BTreeMap<SiteId, BTreeSet<(GatewayId, Ipv4Addr, Ipv6Addr)>>,

    #[debug(skip)]
    sites_by_resource: BTreeMap<ResourceId, SiteId>,

    // TODO: Maybe these should use the `messages` types to cover the conversions and to model that that is what we receive from the portal?
    cidr_resources: BTreeMap<ResourceId, client::CidrResource>,
    dns_resources: BTreeMap<ResourceId, client::DnsResource>,
    internet_resource: client::InternetResource,

    search_domain: Option<DomainName>,
    upstream_do53: Vec<UpstreamDo53>,
    upstream_doh: Vec<UpstreamDoH>,

    #[debug(skip)]
    gateway_selector: Selector,
}

impl StubPortal {
    pub(crate) fn new(
        gateways_by_site: BTreeMap<SiteId, BTreeSet<GatewayId>>,
        gateway_selector: Selector,
        cidr_resources: BTreeSet<client::CidrResource>,
        dns_resources: BTreeSet<client::DnsResource>,
        internet_resource: client::InternetResource,
        search_domain: Option<DomainName>,
        upstream_do53: Vec<UpstreamDo53>,
        upstream_doh: Vec<UpstreamDoH>,
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

        let mut tunnel_ip4s = tunnel_ip4s();
        let mut tunnel_ip6s = tunnel_ip6s();

        let client_tunnel_ipv4 = tunnel_ip4s.next().unwrap();
        let client_tunnel_ipv6 = tunnel_ip6s.next().unwrap();

        let gateways_by_site = gateways_by_site
            .into_iter()
            .map(|(site, gateways)| {
                let gateways = gateways
                    .into_iter()
                    .map(|gateway| {
                        let ipv4_addr = tunnel_ip4s.next().unwrap();
                        let ipv6_addr = tunnel_ip6s.next().unwrap();

                        (gateway, ipv4_addr, ipv6_addr)
                    })
                    .collect();

                (site, gateways)
            })
            .collect();

        Self {
            client_tunnel_ipv4,
            client_tunnel_ipv6,
            gateways_by_site,
            gateway_selector,
            sites_by_resource: BTreeMap::from_iter(
                cidr_sites.chain(dns_sites).chain(internet_site),
            ),
            cidr_resources,
            dns_resources,
            internet_resource,
            search_domain,
            upstream_do53,
            upstream_doh,
        }
    }

    pub(crate) fn all_resources(&self) -> Vec<client::Resource> {
        self.cidr_resources
            .values()
            .cloned()
            .map(client::Resource::Cidr)
            .chain(
                self.dns_resources
                    .values()
                    .cloned()
                    .map(client::Resource::Dns),
            )
            .chain(iter::once(client::Resource::Internet(
                self.internet_resource.clone(),
            )))
            .collect()
    }

    pub(crate) fn dns_resources(&self) -> Vec<client::DnsResource> {
        self.dns_resources.values().cloned().collect()
    }

    pub(crate) fn search_domain(&self) -> Option<DomainName> {
        self.search_domain.clone()
    }

    pub(crate) fn set_search_domain(&mut self, search_domain: Option<DomainName>) {
        self.search_domain = search_domain;
    }

    pub(crate) fn upstream_do53(&self) -> &[UpstreamDo53] {
        &self.upstream_do53
    }

    pub(crate) fn set_upstream_do53(&mut self, upstream_do53: Vec<UpstreamDo53>) {
        self.upstream_do53 = upstream_do53;
    }

    pub(crate) fn upstream_doh(&self) -> &[UpstreamDoH] {
        &self.upstream_doh
    }

    pub(crate) fn set_upstream_doh(&mut self, upstream_doh: Vec<UpstreamDoH>) {
        self.upstream_doh = upstream_doh;
    }

    /// Picks, which gateway and site we should connect to for the given resource.
    pub(crate) fn handle_connection_intent(
        &self,
        resource: ResourceId,
        _connected_gateway_ids: Vec<GatewayId>,
    ) -> (GatewayId, SiteId) {
        let site_id = self
            .sites_by_resource
            .get(&resource)
            .expect("resource to be known");

        let gateways = self.gateways_by_site.get(site_id).unwrap();
        let (gateway, _, _) = self.gateway_selector.select(gateways);

        (*gateway, *site_id)
    }

    pub(crate) fn map_client_resource_to_gateway_resource(
        &self,
        resource_id: ResourceId,
    ) -> gateway::ResourceDescription {
        let cidr_resource = self.cidr_resources.iter().find_map(|(_, r)| {
            (r.id == resource_id).then_some(gateway::ResourceDescription::Cidr(
                gateway::ResourceDescriptionCidr {
                    id: r.id,
                    address: r.address,
                    name: r.name.clone(),
                    filters: Vec::new(),
                },
            ))
        });
        let dns_resource = self.dns_resources.get(&resource_id).map(|r| {
            gateway::ResourceDescription::Dns(gateway::ResourceDescriptionDns {
                id: r.id,
                name: r.name.clone(),
                filters: Vec::new(),
                address: r.address.clone(),
            })
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
        let (gid, _, _) = self.gateway_selector.try_select(gateways)?;

        Some(gid)
    }

    pub(crate) fn gateway_by_ip(&self, ip: IpAddr) -> Option<GatewayId> {
        self.gateways_by_site
            .values()
            .flatten()
            .find(|(_, ipv4_addr, ipv6_addr)| *ipv4_addr == ip || *ipv6_addr == ip)
            .map(|(gid, _, _)| *gid)
    }

    pub(crate) fn change_address_of_cidr_resource(
        &mut self,
        rid: ResourceId,
        new_address: IpNetwork,
    ) {
        if let Some(resource) = self.cidr_resources.get_mut(&rid) {
            resource.address = new_address;
            return;
        }

        tracing::error!(%rid, "Unknown resource");
    }

    pub(crate) fn move_resource_to_new_site(&mut self, rid: ResourceId, site: Site) {
        if let Some(resource) = self.cidr_resources.get_mut(&rid) {
            self.sites_by_resource.insert(rid, site.id);
            resource.sites = vec![site];
            return;
        }

        if let Some(resource) = self.dns_resources.get_mut(&rid) {
            self.sites_by_resource.insert(rid, site.id);
            resource.sites = vec![site];
            return;
        }

        if self.internet_resource.id == rid {
            tracing::error!("Internet Resource cannot change site");
        }
    }

    pub(crate) fn gateways(
        &self,
        at: Instant,
    ) -> impl Strategy<Value = BTreeMap<GatewayId, Host<RefGateway>>> + use<> {
        let dns_resources = self.dns_resources.clone();

        self.gateways_by_site
            .iter()
            .flat_map(|(site_id, gateways)| {
                gateways.iter().map(|(gid, ipv4_addr, ipv6_addr)| {
                    (
                        Just(*gid),
                        ref_gateway_host(
                            Just(*ipv4_addr),
                            Just(*ipv6_addr),
                            site_specific_dns_records(dns_resources.clone(), *site_id, at),
                        ),
                    )
                })
            })
            .collect::<Vec<_>>() // A `Vec<Strategy>` implements `Strategy<Value = Vec<_>>`
            .prop_map(BTreeMap::from_iter)
    }

    pub(crate) fn client<S1>(
        &self,
        system_dns: S1,
    ) -> impl Strategy<Value = Host<RefClient>> + use<S1>
    where
        S1: Strategy<Value = Vec<IpAddr>>,
    {
        ref_client_host(
            Just(self.client_tunnel_ipv4),
            Just(self.client_tunnel_ipv6),
            system_dns,
        )
    }

    pub(crate) fn dns_resource_records(
        &self,
        at: Instant,
    ) -> impl Strategy<Value = DnsRecords> + use<> {
        dns_resource_records(self.dns_resources.clone().into_values(), at)
    }
}

/// Generates site-specific DNS records for a particular site.
fn site_specific_dns_records(
    dns_resources: BTreeMap<ResourceId, client::DnsResource>,
    site: SiteId,
    at: Instant,
) -> impl Strategy<Value = DnsRecords> {
    let dns_resources_in_site = dns_resources
        .into_values()
        .filter(move |resource| resource.sites.iter().any(|s| s.id == site));

    dns_resource_records(dns_resources_in_site, at).prop_flat_map(move |records| {
        if records.is_empty() {
            Just(DnsRecords::default()).boxed()
        } else {
            collection::btree_map(
                sample::select(records.domains_iter().collect::<Vec<_>>()),
                collection::btree_set(site_specific_dns_record(), 1..6)
                    .prop_map(move |records| BTreeMap::from([(at, records)])),
                0..5,
            )
            .prop_map_into()
            .boxed()
        }
    })
}

fn dns_resource_records(
    dns_resources: impl Iterator<Item = DnsResource>,
    at: Instant,
) -> impl Strategy<Value = DnsRecords> {
    dns_resources
        .map(|resource| {
            let address = resource.address;

            // Only generate simple wildcard domains for these tests.
            // The matching logic is extensively unit-tested so we don't need to cover all cases here.
            // What we do want to cover is multiple domains pointing to the same resource.
            // For example, `*.example.com` and `app.example.com`.
            match address.split_once('.') {
                Some(("*" | "**", base)) => {
                    subdomain_records(base.to_owned(), domain_label(), at).boxed()
                }
                _ => resolved_ips()
                    .prop_map(move |resolved_ips| {
                        DnsRecords::from([(
                            address.parse().unwrap(),
                            BTreeMap::from([(at, resolved_ips)]),
                        )])
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

/// An [`Iterator`] over the possible IPv4 addresses of a tunnel interface.
///
/// We use the CG-NAT range for IPv4.
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L7>.
fn tunnel_ip4s() -> impl Iterator<Item = Ipv4Addr> {
    crate::IPV4_TUNNEL.hosts()
}

/// An [`Iterator`] over the possible IPv6 addresses of a tunnel interface.
///
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L8>.
fn tunnel_ip6s() -> impl Iterator<Item = Ipv6Addr> {
    crate::IPV6_TUNNEL
        .subnets_with_prefix(128)
        .map(|n| n.network_address())
}
