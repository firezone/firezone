use connlib_model::{ClientId, GatewayId, ResourceId, Site, SiteId};
use dns_types::DomainName;
use itertools::Itertools;
use smallvec::SmallVec;
use std::{
    collections::{BTreeMap, BTreeSet},
    iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};
use tunnel_proto::dns;
use tunnel_proto::messages::{UpstreamDo53, UpstreamDoH, gateway};

use crate::reference::ReferenceState;
use crate::resource::{self as client, DevicePoolResource};
use crate::transition::Transition;

/// Stub implementation of the portal.
#[derive(Clone, derive_more::Debug)]
pub struct StubPortal {
    clients: BTreeMap<ClientId, StubClient>,
    gateways_by_site: BTreeMap<SiteId, SmallVec<[(GatewayId, Ipv4Addr, Ipv6Addr); 3]>>,
    regular_sites: SmallVec<[Site; 3]>,

    #[debug(skip)]
    sites_by_resource: BTreeMap<ResourceId, SiteId>,

    // TODO: Maybe these should use the `messages` types to cover the conversions and to model that that is what we receive from the portal?
    cidr_resources: BTreeMap<ResourceId, client::CidrResource>,
    dns_resources: BTreeMap<ResourceId, client::DnsResource>,
    device_pool_resources: BTreeMap<ResourceId, DevicePoolResource>,
    /// The portal's membership criteria per pool, evaluated when a client asks for access.
    pool_members: BTreeMap<ResourceId, PoolMembers>,
    /// The peer subset of the portal's persisted policy authorizations.
    peer_policy_authorizations: BTreeSet<PeerAuthorization>,
    /// The Gateway subset of the portal's persisted policy authorizations.
    ///
    /// A revoked one is kept, because the Gateway that held it is what decides whether
    /// it has anything left for the Client.
    gateway_policy_authorizations: BTreeMap<(ClientId, ResourceId), GatewayAuthorization>,
    internet_resource: client::InternetResource,

    search_domain: Option<DomainName>,
    upstream_do53: Vec<UpstreamDo53>,
    upstream_doh: Vec<UpstreamDoH>,

    /// Stable index used to pick a gateway within a site (`index % len`).
    #[debug(skip)]
    gateway_selector: u32,

    /// Stable index used to pick a resource candidate (`index % len`).
    resource_selector: u32,

    /// Whether the portal hands out ICE-less flows. Sampled once per test case
    /// and applied to every connection, modelling a portal-wide rollout toggle
    /// rather than a per-peer capability.
    iceless: bool,
}

/// Which clients a device pool admits.
#[derive(Clone, Debug)]
pub(crate) enum PoolMembers {
    AllClients,
    Listed(BTreeSet<ClientId>),
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct PeerAuthorization {
    pub(crate) initiator: ClientId,
    pub(crate) target: ClientId,
    pub(crate) pool: ResourceId,
}

/// A Gateway connection the portal left with nothing, and what the Client reached
/// through it.
pub(crate) struct ClosedGatewayConnection {
    pub(crate) client: ClientId,
    pub(crate) gateway: GatewayId,
    pub(crate) resources: BTreeSet<ResourceId>,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct GatewayAuthorization {
    gateway: GatewayId,
    revoked: bool,
}

#[derive(Clone, Debug)]
struct StubClient {
    ipv4: Ipv4Addr,
    ipv6: Ipv6Addr,
    /// The slug this client is reached at under the device domain.
    ///
    /// In production the portal derives it from the device name; in the test harness
    /// we assign one stable label per client (e.g. `device0`).
    device_label: String,
}

impl StubPortal {
    pub(crate) fn new(
        clients: impl IntoIterator<Item = (ClientId, Ipv4Addr, Ipv6Addr)>,
        gateways_by_site: BTreeMap<SiteId, SmallVec<[(GatewayId, Ipv4Addr, Ipv6Addr); 3]>>,
        regular_sites: SmallVec<[Site; 3]>,
        gateway_selector: u32,
        resource_selector: u32,
        cidr_resources: impl IntoIterator<Item = client::CidrResource>,
        dns_resources: impl IntoIterator<Item = client::DnsResource>,
        device_pool_resources: impl IntoIterator<Item = (DevicePoolResource, PoolMembers)>,
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
        let (device_pool_resources, pool_members) = device_pool_resources
            .into_iter()
            .map(|(r, members)| ((r.id, r.clone()), (r.id, members)))
            .unzip::<_, _, BTreeMap<_, _>, BTreeMap<_, _>>();

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
            resource_selector,
            sites_by_resource: BTreeMap::from_iter(
                cidr_sites.chain(dns_sites).chain(internet_site),
            ),
            cidr_resources,
            dns_resources,
            device_pool_resources,
            pool_members,
            peer_policy_authorizations: Default::default(),
            gateway_policy_authorizations: Default::default(),
            internet_resource,
            search_domain,
            upstream_do53,
            upstream_doh,
            iceless: false,
        }
    }

    /// Applies the portal-side effect of `transition`.
    pub fn apply(&mut self, transition: &Transition, reference: &ReferenceState) {
        match transition {
            Transition::RemoveResource(id) => {
                self.revoke_policy_authorizations(*id);
            }
            Transition::EditResource(edit) => {
                if matches!(
                    client::classify(&edit.old, &edit.new),
                    client::EditEffect::Filters { .. }
                        | client::EditEffect::Access { .. }
                        | client::EditEffect::Type { .. }
                ) {
                    self.revoke_disconnected_gateway_authorizations(edit.old.id(), reference);
                }

                // An edit that changes who may reach what invalidates the authorizations
                // the resource granted; the Clients ask for new ones.
                if matches!(
                    client::classify(&edit.old, &edit.new),
                    client::EditEffect::Access { .. } | client::EditEffect::Type { .. }
                ) {
                    self.revoke_policy_authorizations(edit.old.id());
                }

                self.replace_resource(edit.new.clone());
            }
            Transition::UpdateDevicePoolMembers {
                pool_id,
                members,
                revoked: _,
            } => {
                self.set_pool_members(*pool_id, members.clone());
            }
            Transition::UpdateUpstreamDo53Servers(servers) => {
                self.upstream_do53 = servers.clone();
            }
            Transition::UpdateUpstreamDoHServers(servers) => {
                self.upstream_doh = servers.clone();
            }
            Transition::UpdateUpstreamSearchDomain(domain) => {
                self.search_domain = domain.clone();
            }
            Transition::AddResource(_) => {}
            Transition::SetInternetResourceState { .. } => {}
            Transition::SendIcmpPacketOnNewFlow { .. } => {}
            Transition::SendIcmpPacketOnExistingFlow { .. } => {}
            Transition::SendUdpPacketOnNewFlow { .. } => {}
            Transition::SendUdpPacketOnExistingFlow { .. } => {}
            Transition::ConnectTcp { .. } => {}
            Transition::SendDnsQuery { .. } => {}
            Transition::SendDnsResourcePtrQuery { .. } => {}
            Transition::UpdateSystemDnsServers { .. } => {}
            Transition::RoamClient { .. } => {}
            Transition::ReconnectPortal { .. } => {}
            Transition::RestartClient { .. } => {}
            Transition::DeployNewRelays(_) => {}
            Transition::PartitionRelaysFromPortal => {}
            Transition::Idle => {}
            Transition::RebootRelaysWhilePartitioned(_) => {}
            Transition::DeauthorizeWhileGatewayIsPartitioned(resource) => {
                self.revoke_policy_authorizations(*resource);
            }
            Transition::RevokeGatewayAuthorization(resource) => {
                self.revoke_policy_authorizations(*resource);
            }
            Transition::ExpirePeerAuthorizations { .. } => {}
            Transition::UpdateDnsRecords { .. } => {}
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

    /// Resolves a device name (e.g. `device0.firezone.network`) to the matching client's
    /// tunnel IPv4 + IPv6, if the slug corresponds to a known device.
    pub(crate) fn resolve_device_domain(
        &self,
        domain: &DomainName,
    ) -> Option<(Ipv4Addr, Ipv6Addr)> {
        let slug = dns::device_slug(domain)?;

        let client = self.clients.values().find(|c| c.device_label == slug)?;

        Some((client.ipv4, client.ipv6))
    }

    pub(crate) fn client_by_ip(&self, ip: IpAddr) -> Option<ClientId> {
        self.clients
            .iter()
            .find(|(_, c)| IpAddr::V4(c.ipv4) == ip || IpAddr::V6(c.ipv6) == ip)
            .map(|(id, _)| *id)
    }

    /// The pool the portal picks for a flow from a client holding `held` to `target`:
    /// the first by id that admits the target and permits the protocol.
    /// The first of the pools the client named, in its order, that holds the target.
    pub(crate) fn pick_device_pool(
        &self,
        candidates: &[ResourceId],
        target: ClientId,
    ) -> Option<ResourceId> {
        candidates.iter().copied().find(|pool| {
            self.device_pool_resources.contains_key(pool) && self.is_pool_member(*pool, target)
        })
    }

    /// Authorizes `initiator` to reach `target`, naming the pool that admits it.
    pub(crate) fn request_peer_access(
        &mut self,
        initiator: ClientId,
        target: ClientId,
        candidates: &[ResourceId],
    ) -> Option<ResourceId> {
        let pool = self.pick_device_pool(candidates, target)?;

        self.peer_policy_authorizations.insert(PeerAuthorization {
            initiator,
            target,
            pool,
        });

        Some(pool)
    }

    /// Whether a Gateway still holds an authorization for `client` to reach `resource`.
    pub(crate) fn holds_gateway_authorization(
        &self,
        client: ClientId,
        resource: ResourceId,
    ) -> bool {
        self.gateway_policy_authorizations
            .get(&(client, resource))
            .is_some_and(|authorization| !authorization.revoked)
    }

    /// Resources some Gateway currently holds an authorization for.
    pub(crate) fn authorized_resources(&self) -> BTreeSet<ResourceId> {
        self.gateway_policy_authorizations
            .iter()
            .filter(|(_, authorization)| !authorization.revoked)
            .map(|((_, resource), _)| *resource)
            .collect()
    }

    /// The connections that revoking `resource` left a Gateway with nothing on. It closes
    /// them with a `goodbye`.
    pub(crate) fn gateway_connections_closed_by(
        &self,
        resource: ResourceId,
    ) -> Vec<ClosedGatewayConnection> {
        self.gateway_policy_authorizations
            .iter()
            .filter(|((_, candidate), authorization)| {
                *candidate == resource && authorization.revoked
            })
            .map(|((client, _), authorization)| (*client, authorization.gateway))
            .filter(|(client, gateway)| !self.holds_any_gateway_authorization(*client, *gateway))
            .map(|(client, gateway)| ClosedGatewayConnection {
                client,
                resources: self.resources_on_gateway(client, gateway),
                gateway,
            })
            .collect()
    }

    /// Everything `client` was authorized to reach through `gateway`, revoked or not.
    fn resources_on_gateway(&self, client: ClientId, gateway: GatewayId) -> BTreeSet<ResourceId> {
        self.gateway_policy_authorizations
            .iter()
            .filter(|((candidate, _), authorization)| {
                *candidate == client && authorization.gateway == gateway
            })
            .map(|((_, resource), _)| *resource)
            .collect()
    }

    fn holds_any_gateway_authorization(&self, client: ClientId, gateway: GatewayId) -> bool {
        self.gateway_policy_authorizations
            .iter()
            .any(|((candidate, _), authorization)| {
                *candidate == client && authorization.gateway == gateway && !authorization.revoked
            })
    }

    /// Revokes grants lost when an edit disconnects the last resource on a Gateway.
    fn revoke_disconnected_gateway_authorizations(
        &mut self,
        resource: ResourceId,
        reference: &ReferenceState,
    ) {
        let Some(gateway) = self.gateway_for_resource(resource).copied() else {
            return;
        };

        for (client_id, client) in &reference.clients {
            let connected = client
                .inner()
                .connected_resources()
                .collect::<BTreeSet<_>>();
            if !connected.contains(&resource)
                || connected.iter().any(|candidate| {
                    *candidate != resource
                        && self.gateway_for_resource(*candidate) == Some(&gateway)
                })
            {
                continue;
            }

            for (_, authorization) in self.gateway_policy_authorizations.iter_mut().filter(
                |((candidate, _), authorization)| {
                    candidate == client_id && authorization.gateway == gateway
                },
            ) {
                authorization.revoked = true;
            }
        }
    }

    /// Revokes every authorization `resource` granted, to a peer or through a Gateway.
    fn revoke_policy_authorizations(&mut self, resource: ResourceId) {
        for _ in self
            .peer_policy_authorizations
            .extract_if(.., |authorization| authorization.pool == resource)
        {}

        for (_, authorization) in self
            .gateway_policy_authorizations
            .iter_mut()
            .filter(|((_, candidate), _)| *candidate == resource)
        {
            authorization.revoked = true;
        }
    }

    fn is_pool_member(&self, pool: ResourceId, client: ClientId) -> bool {
        match self.pool_members.get(&pool) {
            Some(PoolMembers::AllClients) => self.clients.contains_key(&client),
            Some(PoolMembers::Listed(members)) => members.contains(&client),
            None => false,
        }
    }

    /// The clients a pool admits.
    pub(crate) fn pool_members(&self, pool: ResourceId) -> Vec<ClientId> {
        self.clients
            .keys()
            .copied()
            .filter(|client| self.is_pool_member(pool, *client))
            .collect()
    }

    /// Returns every pool that lists its members.
    pub(crate) fn listed_pool_ids(&self) -> Vec<ResourceId> {
        self.pool_members
            .iter()
            .filter_map(|(pool, members)| match members {
                PoolMembers::Listed(_) => Some(*pool),
                PoolMembers::AllClients => None,
            })
            .collect()
    }

    /// The peer authorizations through `pool` that setting its members to `members` revokes.
    pub(crate) fn peer_authorizations_revoked_by(
        &self,
        pool: ResourceId,
        members: &BTreeSet<ClientId>,
    ) -> Vec<PeerAuthorization> {
        self.peer_policy_authorizations
            .iter()
            .filter(|authorization| {
                authorization.pool == pool && !members.contains(&authorization.target)
            })
            .copied()
            .collect()
    }

    fn set_pool_members(&mut self, pool: ResourceId, members: BTreeSet<ClientId>) {
        if !self.device_pool_resources.contains_key(&pool) {
            tracing::error!(%pool, "Unknown device pool");
            return;
        }

        for authorization in self.peer_authorizations_revoked_by(pool, &members) {
            self.peer_policy_authorizations.remove(&authorization);
        }
        self.pool_members.insert(pool, PoolMembers::Listed(members));
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
                    .map(client::Resource::DevicePool),
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

    pub(crate) fn upstream_do53(&self) -> &[UpstreamDo53] {
        &self.upstream_do53
    }

    pub(crate) fn upstream_doh(&self) -> &[UpstreamDoH] {
        &self.upstream_doh
    }

    pub(crate) fn resource_selector(&self) -> u32 {
        self.resource_selector
    }

    pub(crate) fn pick_resource(&self, candidates: &[ResourceId]) -> Option<ResourceId> {
        select_by_index(candidates, self.resource_selector).copied()
    }

    /// Authorizes `client` to reach `resource`, naming the Gateway that serves it.
    pub(crate) fn request_resource_access(
        &mut self,
        client: ClientId,
        resource: ResourceId,
        _connected_gateway_ids: Vec<GatewayId>,
    ) -> (GatewayId, SiteId) {
        let site_id = *self
            .sites_by_resource
            .get(&resource)
            .expect("resource to be known");

        let gateways = &self.gateways_by_site[&site_id];
        let (gateway, _, _) =
            select_by_index(gateways, self.gateway_selector).expect("site to have a gateway");
        let gateway = *gateway;

        self.gateway_policy_authorizations.insert(
            (client, resource),
            GatewayAuthorization {
                gateway,
                revoked: false,
            },
        );

        (gateway, site_id)
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

    fn replace_resource(&mut self, new_resource: client::Resource) {
        let id = new_resource.id();

        self.cidr_resources.remove(&id);
        self.dns_resources.remove(&id);
        self.device_pool_resources.remove(&id);
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
            client::Resource::DevicePool(resource) => {
                // A resource turned into a pool admits everyone until its members change.
                self.pool_members
                    .entry(id)
                    .or_insert(PoolMembers::AllClients);
                self.device_pool_resources.insert(id, resource);
            }
            client::Resource::Internet(_) => {
                unreachable!("the Portal API does not allow editing the Internet Resource")
            }
        }

        if !self.device_pool_resources.contains_key(&id) {
            self.pool_members.remove(&id);
        }
    }

    /// The filters of a device pool.
    pub(crate) fn device_pool_filters(
        &self,
        pool_id: ResourceId,
    ) -> Option<Vec<tunnel_proto::messages::Filter>> {
        Some(self.device_pool_resources.get(&pool_id)?.filters.clone())
    }
}

/// Picks an element from a slice by index (`index % len`), or `None` if empty.
///
fn select_by_index<T>(values: &[T], index: u32) -> Option<&T> {
    let len = values.len();
    (len > 0).then(|| &values[index as usize % len])
}
