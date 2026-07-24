use connlib_model::{ClientId, GatewayId, ResourceId, Site, SiteId};
use dns_types::DomainName;
use ip_network::IpNetwork;
use itertools::Itertools;
use smallvec::SmallVec;
use std::{
    collections::BTreeMap,
    iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};
use tunnel_proto::messages::{UpstreamDo53, UpstreamDoH, client::DevicePoolMember, gateway};

use crate::resource::{self as client, DynamicDevicePoolResource, StaticDevicePoolResource};

/// Stub implementation of the portal.
#[derive(Clone, derive_more::Debug)]
pub(crate) struct StubPortal {
    clients: BTreeMap<ClientId, StubClient>,
    gateways_by_site: BTreeMap<SiteId, SmallVec<[(GatewayId, Ipv4Addr, Ipv6Addr); 3]>>,
    regular_sites: SmallVec<[Site; 3]>,

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
        clients: impl IntoIterator<Item = (ClientId, Ipv4Addr, Ipv6Addr)>,
        gateways_by_site: BTreeMap<SiteId, SmallVec<[(GatewayId, Ipv4Addr, Ipv6Addr); 3]>>,
        regular_sites: SmallVec<[Site; 3]>,
        gateway_selector: u32,
        cidr_resources: impl IntoIterator<Item = client::CidrResource>,
        dns_resources: impl IntoIterator<Item = client::DnsResource>,
        device_pool_resources: impl IntoIterator<Item = DynamicDevicePoolResource>,
        static_device_pool_resources: impl IntoIterator<Item = StaticDevicePoolResource>,
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
        let static_device_pool_resources = static_device_pool_resources
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

        let clients = clients
            .into_iter()
            .enumerate()
            .map(|(idx, (id, ipv4, ipv6))| {
                let client = StubClient {
                    ipv4,
                    ipv6,
                    device_label: format!("device{idx}"),
                };

                (id, client)
            })
            .collect();

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
    pub(crate) fn client_tunnel_ips(
        &self,
    ) -> impl Iterator<Item = (ClientId, Ipv4Addr, Ipv6Addr)> + '_ {
        self.clients.iter().map(|(id, c)| (*id, c.ipv4, c.ipv6))
    }

    /// The tunnel IPs and owning site of each gateway.
    pub(crate) fn gateway_tunnel_ips(
        &self,
    ) -> impl Iterator<Item = (GatewayId, Ipv4Addr, Ipv6Addr, SiteId)> + '_ {
        self.gateways_by_site
            .iter()
            .flat_map(|(site_id, gateways)| {
                gateways
                    .iter()
                    .map(move |(gid, ipv4, ipv6)| (*gid, *ipv4, *ipv6, *site_id))
            })
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

    pub(crate) fn regular_sites(&self) -> &[Site] {
        &self.regular_sites
    }

    pub(crate) fn dns_resources(&self) -> impl Iterator<Item = &client::DnsResource> {
        self.dns_resources.values()
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

/// Picks an element from a slice by index (`index % len`), or `None` if empty.
///
fn select_by_index<T>(values: &[T], index: u32) -> Option<&T> {
    let len = values.len();
    (len > 0).then(|| &values[index as usize % len])
}
