use super::{
    dns_records::DnsRecords,
    ref_client::{RefClient, ref_client_host},
    ref_gateway::{RefGateway, ref_gateway_host},
    sim_net::Host,
    strategies::{resolved_ips, site_specific_dns_record, subdomain_records},
};
use connlib_model::{ClientId, GatewayId, ResourceId, Site, SiteId};
use dns_types::DomainName;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools;
use proptest::{
    collection, sample,
    strategy::{Just, Strategy},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::Instant,
};
use tunnel::{
    client,
    client::{DnsResource, DynamicDevicePoolResource, StaticDevicePoolResource},
    messages::{UpstreamDo53, UpstreamDoH, client::DevicePoolMember, gateway},
    proptest::*,
};

/// Stub implementation of the portal.
#[derive(Clone, derive_more::Debug)]
pub(crate) struct StubPortal {
    clients: BTreeMap<ClientId, StubClient>,
    gateways_by_site: BTreeMap<SiteId, BTreeSet<(GatewayId, Ipv4Addr, Ipv6Addr)>>,

    #[debug(skip)]
    sites_by_resource: BTreeMap<ResourceId, SiteId>,

    // TODO: Maybe these should use the `messages` types to cover the conversions and to model that that is what we receive from the portal?
    cidr_resources: BTreeMap<ResourceId, client::CidrResource>,
    dns_resources: BTreeMap<ResourceId, client::DnsResource>,
    device_pool_resources: BTreeMap<ResourceId, DynamicDevicePoolResource>,
    static_device_pool_resources: BTreeMap<ResourceId, StaticDevicePoolResource>,
    internet_resource: client::InternetResource,

    search_domain: Option<DomainName>,
    upstream_do53: Vec<UpstreamDo53>,
    upstream_doh: Vec<UpstreamDoH>,

    /// Index used to pick a gateway within a site (selected with `% len`).
    ///
    /// Replaces `proptest::sample::Selector`, which cannot be constructed from
    /// `arbitrary::Unstructured` (no public constructor).
    #[debug(skip)]
    gateway_selector: u32,

    /// Whether the portal hands out ICE-less flows. Sampled once per test case
    /// and applied to every connection, modelling a portal-wide rollout toggle
    /// rather than a per-peer capability.
    iceless: bool,
}

#[derive(Clone, Debug)]
struct StubClient {
    ipv4: Ipv4Addr,
    ipv6: Ipv6Addr,
    /// Label under which this client is registered as a device in dynamic device pools.
    ///
    /// In production the portal maps each device to a tunnel IP; in the test harness
    /// we assign one stable label per client (e.g. `device0`) and use it for all pools.
    device_label: String,
}

impl StubPortal {
    pub(crate) fn new(
        clients: BTreeSet<ClientId>,
        gateways_by_site: BTreeMap<SiteId, BTreeSet<GatewayId>>,
        gateway_selector: u32,
        cidr_resources: BTreeSet<client::CidrResource>,
        dns_resources: BTreeSet<client::DnsResource>,
        device_pool_resources: BTreeSet<DynamicDevicePoolResource>,
        static_device_pool_plans: Vec<StaticDevicePoolPlan>,
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
        let device_pool_resources = device_pool_resources
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

        let clients = clients
            .into_iter()
            .enumerate()
            .map(|(idx, id)| {
                let client = StubClient {
                    ipv4: tunnel_ip4s.next().unwrap(),
                    ipv6: tunnel_ip6s.next().unwrap(),
                    device_label: format!("device{idx}"),
                };

                (id, client)
            })
            .collect();

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

        let static_device_pool_resources = realize_static_device_pool_plans(
            static_device_pool_plans,
            &clients,
            &mut tunnel_ip4s,
            &mut tunnel_ip6s,
        );

        Self {
            clients,
            gateways_by_site,
            gateway_selector,
            sites_by_resource: BTreeMap::from_iter(
                cidr_sites.chain(dns_sites).chain(internet_site),
            ),
            cidr_resources,
            dns_resources,
            device_pool_resources,
            static_device_pool_resources,
            internet_resource,
            search_domain,
            upstream_do53,
            upstream_doh,
            iceless: false,
        }
    }

    /// The tunnel IPs assigned to each client, in client order.
    ///
    /// Used by the structured generator to materialize client hosts without going
    /// through the `clients(...)` proptest strategy.
    pub(crate) fn client_tunnel_ips(&self) -> Vec<(ClientId, Ipv4Addr, Ipv6Addr)> {
        self.clients
            .iter()
            .map(|(id, c)| (*id, c.ipv4, c.ipv6))
            .collect()
    }

    /// The tunnel IPs and owning site of each gateway.
    pub(crate) fn gateway_tunnel_ips(&self) -> Vec<(GatewayId, Ipv4Addr, Ipv6Addr, SiteId)> {
        self.gateways_by_site
            .iter()
            .flat_map(|(site_id, gateways)| {
                gateways
                    .iter()
                    .map(move |(gid, ipv4, ipv6)| (*gid, *ipv4, *ipv6, *site_id))
            })
            .collect()
    }

    /// Toggles whether the portal hands out ICE-less flows.
    pub(crate) fn with_iceless(mut self, iceless: bool) -> Self {
        self.iceless = iceless;
        self
    }

    /// Whether the portal hands out ICE-less flows for every connection.
    pub(crate) fn iceless(&self) -> bool {
        self.iceless
    }

    /// All device labels the portal knows about, in client order.
    pub(crate) fn device_labels(&self) -> Vec<String> {
        self.clients
            .values()
            .map(|c| c.device_label.clone())
            .collect()
    }

    /// Resolves a device-pool domain (e.g. `device0.pool.example.com`) to the
    /// tunnel IPv4 + IPv6 of the matching client, if the label corresponds to a known
    /// device.
    pub(crate) fn resolve_device_pool_domain(&self, domain: &str) -> Option<(Ipv4Addr, Ipv6Addr)> {
        let label = domain.split_once('.')?.0;

        let client = self
            .clients
            .values()
            .find(|c| c.device_label.as_str() == label)?;

        Some((client.ipv4, client.ipv6))
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
            .chain(
                self.device_pool_resources
                    .values()
                    .cloned()
                    .map(client::Resource::DynamicDevicePool),
            )
            .chain(
                self.static_device_pool_resources
                    .values()
                    .cloned()
                    .map(client::Resource::StaticDevicePool),
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
        let (gateway, _, _) =
            select_by_index(gateways, self.gateway_selector).expect("site to have a gateway");

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
                    filters: r.filters.clone(),
                },
            ))
        });
        let dns_resource = self.dns_resources.get(&resource_id).map(|r| {
            gateway::ResourceDescription::Dns(gateway::ResourceDescriptionDns {
                id: r.id,
                name: r.name.clone(),
                filters: r.filters.clone(),
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
        let (gid, _, _) = select_by_index(gateways, self.gateway_selector)?;

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

    pub(crate) fn change_filters_of_resource(
        &mut self,
        rid: ResourceId,
        new_filters: Vec<tunnel::messages::Filter>,
    ) {
        if let Some(resource) = self.cidr_resources.get_mut(&rid) {
            resource.filters = new_filters;
            return;
        }

        if let Some(resource) = self.dns_resources.get_mut(&rid) {
            resource.filters = new_filters;
            return;
        }

        if let Some(resource) = self.static_device_pool_resources.get_mut(&rid) {
            resource.filters = new_filters;
            return;
        }

        tracing::error!(%rid, "Unknown resource");
    }

    /// Replaces the member list of an existing static device pool.
    ///
    /// Returns the updated pool, or `None` if no pool with `pool_id` exists.
    pub(crate) fn update_static_device_pool_members(
        &mut self,
        pool_id: ResourceId,
        new_devices: Vec<DevicePoolMember>,
    ) -> Option<StaticDevicePoolResource> {
        let pool = self.static_device_pool_resources.get_mut(&pool_id)?;
        pool.devices = new_devices;
        Some(pool.clone())
    }

    pub(crate) fn static_device_pool_filters(
        &self,
        pool_id: ResourceId,
    ) -> Option<Vec<tunnel::messages::Filter>> {
        Some(
            self.static_device_pool_resources
                .get(&pool_id)?
                .filters
                .clone(),
        )
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

    pub(crate) fn clients<S1>(
        &self,
        system_dns: S1,
    ) -> impl Strategy<Value = BTreeMap<ClientId, Host<RefClient>>> + use<S1>
    where
        S1: Strategy<Value = Vec<IpAddr>> + Clone,
    {
        self.clients
            .iter()
            .map(|(id, client)| {
                (
                    Just(*id),
                    ref_client_host(
                        *id,
                        Just(client.ipv4),
                        Just(client.ipv6),
                        system_dns.clone(),
                    ),
                )
            })
            .collect::<Vec<_>>()
            .prop_map(BTreeMap::from_iter)
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

/// Picks an element from a set by index (`index % len`), or `None` if empty.
///
/// Used in place of `proptest::sample::Selector::select`/`try_select` so the
/// gateway choice can be driven by a plain `u32` (and thus by `arbitrary`).
fn select_by_index<T>(set: &BTreeSet<T>, index: u32) -> Option<&T> {
    let len = set.len();
    if len == 0 {
        return None;
    }

    set.iter().nth(index as usize % len)
}

/// Materializes static-device-pool plans into [`StaticDevicePoolResource`]s.
///
/// For each plan, picks `n_online_members` deterministic clients from the
/// portal's known clients and pulls `n_offline_members` fresh tunnel IPs
/// (paired with synthetic [`ClientId`]s) for members that are not part of any
/// real test client. This way each pool exercises both the
/// "client already connected" and "client unknown" routing paths.
fn realize_static_device_pool_plans(
    plans: Vec<StaticDevicePoolPlan>,
    clients: &BTreeMap<ClientId, StubClient>,
    tunnel_ip4s: &mut impl Iterator<Item = Ipv4Addr>,
    tunnel_ip6s: &mut impl Iterator<Item = Ipv6Addr>,
) -> BTreeMap<ResourceId, StaticDevicePoolResource> {
    let online_pool = clients.iter().collect::<Vec<_>>();

    plans
        .into_iter()
        .map(|plan| {
            let StaticDevicePoolPlan {
                id,
                name,
                filters,
                n_online_members,
                offline_members,
            } = plan;

            let online_devices =
                online_pool
                    .iter()
                    .take(n_online_members)
                    .map(|(cid, c)| DevicePoolMember {
                        id: **cid,
                        ipv4: Ipv4Network::new(c.ipv4, 32).unwrap(),
                        ipv6: Ipv6Network::new(c.ipv6, 128).unwrap(),
                    });

            let offline_devices = offline_members.into_iter().map(|cid| DevicePoolMember {
                id: cid,
                ipv4: Ipv4Network::new(tunnel_ip4s.next().unwrap(), 32).unwrap(),
                ipv6: Ipv6Network::new(tunnel_ip6s.next().unwrap(), 128).unwrap(),
            });

            let devices = online_devices.chain(offline_devices).collect();

            let resource = StaticDevicePoolResource {
                id,
                name,
                devices,
                filters,
            };

            (id, resource)
        })
        .collect()
}

/// An [`Iterator`] over the possible IPv4 addresses of a tunnel interface.
///
/// We use the CG-NAT range for IPv4.
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L7>.
fn tunnel_ip4s() -> impl Iterator<Item = Ipv4Addr> {
    tunnel::IPV4_TUNNEL.hosts()
}

/// An [`Iterator`] over the possible IPv6 addresses of a tunnel interface.
///
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L8>.
fn tunnel_ip6s() -> impl Iterator<Item = Ipv6Addr> {
    tunnel::IPV6_TUNNEL
        .subnets_with_prefix(128)
        .map(|n| n.network_address())
}
