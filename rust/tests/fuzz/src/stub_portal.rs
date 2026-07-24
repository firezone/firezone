use connlib_model::{ClientId, GatewayId, ResourceId, Site, SiteId};
use dns_types::DomainName;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools;
use std::{
    collections::{BTreeMap, BTreeSet},
    iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};
use tunnel_proto::messages::{
    Filter, UpstreamDo53, UpstreamDoH, client::DevicePoolMember, gateway,
};

use crate::resource::{self as client, DynamicDevicePoolResource, StaticDevicePoolResource};

/// Number of online members and synthetic ClientIds for offline members in a sampled
/// static device pool.
///
/// This is a "plan" rather than a fully-realized resource because at sample-time we don't
/// yet know the IPs of the test clients. The plan gets materialized into a real
/// `StaticDevicePoolResource` once the [`StubPortal`] has assigned tunnel IPs to clients.
#[derive(Clone, Debug)]
pub(crate) struct StaticDevicePoolPlan {
    pub id: ResourceId,
    pub name: String,
    pub filters: Vec<Filter>,
    pub n_online_members: usize,
    /// Synthetic [`ClientId`]s for pool members that are not part of the test's
    /// online clients — exercises the "device unknown / not connected" path.
    pub offline_members: Vec<ClientId>,
}

/// Stub implementation of the portal.
#[derive(Clone, derive_more::Debug)]
pub(crate) struct StubPortal {
    clients: BTreeMap<ClientId, StubClient>,
    gateways_by_site: BTreeMap<SiteId, BTreeSet<(GatewayId, Ipv4Addr, Ipv6Addr)>>,
    regular_sites: Vec<Site>,

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

    /// Stable index used to pick a gateway within a site (`index % len`).
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
        regular_sites: Vec<Site>,
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
            regular_sites,
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
    /// Used by the structured generator to materialize client hosts.
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

    pub(crate) fn regular_sites(&self) -> Vec<Site> {
        self.regular_sites.clone()
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
        new_filters: Vec<tunnel_proto::messages::Filter>,
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

    pub(crate) fn replace_resource(&mut self, new_resource: client::Resource) {
        let id = new_resource.id();

        self.cidr_resources.remove(&id);
        self.dns_resources.remove(&id);
        self.static_device_pool_resources.remove(&id);
        self.sites_by_resource.remove(&id);

        match new_resource {
            client::Resource::Cidr(resource) => {
                let site = resource
                    .sites
                    .iter()
                    .exactly_one()
                    .expect("only single-site resources");
                self.sites_by_resource.insert(id, site.id);
                self.cidr_resources.insert(id, resource);
            }
            client::Resource::Dns(resource) => {
                let site = resource
                    .sites
                    .iter()
                    .exactly_one()
                    .expect("only single-site resources");
                self.sites_by_resource.insert(id, site.id);
                self.dns_resources.insert(id, resource);
            }
            client::Resource::StaticDevicePool(resource) => {
                self.static_device_pool_resources.insert(id, resource);
            }
            client::Resource::Internet(_) | client::Resource::DynamicDevicePool(_) => {
                unreachable!("only user-editable resource types can replace one another")
            }
        }
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
    ) -> Option<Vec<tunnel_proto::messages::Filter>> {
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
}

/// Picks an element from a set by index (`index % len`), or `None` if empty.
///
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
    tunnel_proto::IPV4_TUNNEL.hosts()
}

/// An [`Iterator`] over the possible IPv6 addresses of a tunnel interface.
///
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L8>.
fn tunnel_ip6s() -> impl Iterator<Item = Ipv6Addr> {
    tunnel_proto::IPV6_TUNNEL
        .subnets_with_prefix(128)
        .map(|n| n.network_address())
}
