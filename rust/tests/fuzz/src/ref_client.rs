use super::{
    QueryId,
    dns_records::DnsRecords,
    icmp_error_hosts::IcmpErrorHosts,
    probe::{ExpectedOutcome, RejectionResponse, Remote, Route},
    reference::PrivateKey,
    resource::{
        CidrResource, DevicePoolResource, DnsResource, EditEffect, InternetResource, Resource,
        classify,
    },
    sim_client::SimClient,
    sim_net::ExecMutScope,
    transition::{DPort, Destination, DnsQuery, DnsTransport, SPort},
};
use tunnel_proto::{
    ClientState, MaliciousBehaviour, dns,
    messages::{Filter, Interface, UpstreamDo53, UpstreamDoH},
};

use chrono::{DateTime, Utc};
use connlib_model::{ClientId, GatewayId, ResourceId, ResourceStatus, ResourceView, Site, SiteId};
use dns_types::{DomainName, RecordType};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_packet::Protocol;
use itertools::Itertools as _;
use std::{
    cmp::Ordering,
    collections::{BTreeMap, BTreeSet, VecDeque},
    iter, mem,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant},
};

/// Reference state for a particular client.
///
/// The reference state machine is designed to be as abstract as possible over connlib's functionality.
/// For example, we try to model connectivity to _resources_ and don't really care, which gateway is being used to route us there.
#[derive(Clone, derive_more::Debug)]
pub struct RefClient {
    id: ClientId,

    pub(crate) key: PrivateKey,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,

    /// The DNS resolvers configured on the client outside of connlib.
    #[debug(skip)]
    system_dns_resolvers: Vec<IpAddr>,

    routes: Vec<(ResourceId, IpNetwork)>,

    /// Sampled malicious behaviours for this client.
    pub(crate) malicious_behaviour: MaliciousBehaviour,

    /// The operating system this client simulates.
    pub(crate) os: crate::os::SimulatedOs,

    /// Tracks all resources in the order they have been added in.
    ///
    /// When reconnecting to the portal, we simulate them being re-added in the same order.
    #[debug(skip)]
    resources: Vec<Resource>,

    pub(crate) internet_resource_active: bool,

    /// The client's DNS records.
    ///
    /// The IPs assigned to a domain by connlib are an implementation detail that we don't want to model in these tests.
    /// Instead, we just remember what _kind_ of records we resolved to be able to sample a matching src IP.
    #[debug(skip)]
    pub(crate) dns_records: BTreeMap<DomainName, BTreeSet<RecordType>>,

    /// Whether we are connected to the gateway serving the Internet resource.
    #[debug(skip)]
    pub(crate) connected_internet_resource: bool,

    /// The CIDR resources the client is connected to.
    #[debug(skip)]
    pub(crate) connected_cidr_resources: BTreeSet<ResourceId>,

    /// The DNS resources the client is connected to.
    #[debug(skip)]
    pub(crate) connected_dns_resources: BTreeSet<ResourceId>,

    /// The current record kinds resolved by a connected gateway for each DNS resource domain.
    #[debug(skip)]
    dns_resource_resolutions: BTreeMap<(ResourceId, DomainName), BTreeSet<RecordType>>,

    /// The [`ResourceStatus`] of each site.
    #[debug(skip)]
    site_status: BTreeMap<SiteId, ResourceStatus>,

    /// The expected TCP connections.
    #[debug(skip)]
    pub(crate) expected_tcp_connections: BTreeMap<(IpAddr, Destination, SPort, DPort), ResourceId>,

    /// Tracks TCP connections expected to receive an ICMP error response.
    #[debug(skip)]
    pub(crate) expected_tcp_rejections: BTreeMap<(SPort, DPort), RejectionResponse>,

    /// The expected UDP DNS handshakes.
    #[debug(skip)]
    pub(crate) expected_udp_dns_handshakes: VecDeque<(dns::Upstream, QueryId, u16)>,
    /// The expected TCP DNS handshakes.
    #[debug(skip)]
    pub(crate) expected_tcp_dns_handshakes: VecDeque<(dns::Upstream, QueryId)>,

    #[debug(skip)]
    connection_resets: Vec<Instant>,

    /// Per Gateway, the instants at which this client sent a packet on that
    /// connection.
    #[debug(skip)]
    gateway_send_times: BTreeMap<GatewayId, BTreeSet<Instant>>,

    /// Per peer Client, the instants at which this client sent a packet on that
    /// connection.
    #[debug(skip)]
    client_send_times: BTreeMap<ClientId, BTreeSet<Instant>>,

    /// Per peer, the pools the portal authorised us to reach it through.
    #[debug(skip)]
    outbound_peer_authorizations: BTreeMap<ClientId, BTreeSet<ResourceId>>,

    /// Per peer, the pools through which the portal authorised it to reach us.
    #[debug(skip)]
    inbound_peer_authorizations: BTreeMap<ClientId, BTreeSet<ResourceId>>,
    #[debug(skip)]
    rejected_inbound_peer_authorizations: BTreeMap<ClientId, BTreeMap<ResourceId, Vec<Filter>>>,

    resource_selector: u32,
}

impl RefClient {
    /// Construct a fresh [`RefClient`] with all derived collections empty.
    ///
    /// The structured generator supplies all independent values; this
    /// constructor initializes the derived reference-model state.
    pub(crate) fn new(
        id: ClientId,
        key: PrivateKey,
        tunnel_ip4: Ipv4Addr,
        tunnel_ip6: Ipv6Addr,
        system_dns_resolvers: Vec<IpAddr>,
        internet_resource_active: bool,
        malicious_behaviour: MaliciousBehaviour,
        os: crate::os::SimulatedOs,
        resource_selector: u32,
    ) -> Self {
        Self {
            id,
            key,
            tunnel_ip4,
            tunnel_ip6,
            system_dns_resolvers,
            internet_resource_active,
            malicious_behaviour,
            os,
            resource_selector,
            dns_records: Default::default(),
            connected_cidr_resources: Default::default(),
            connected_dns_resources: Default::default(),
            dns_resource_resolutions: Default::default(),
            connected_internet_resource: Default::default(),
            expected_tcp_connections: Default::default(),
            expected_tcp_rejections: Default::default(),
            expected_udp_dns_handshakes: Default::default(),
            expected_tcp_dns_handshakes: Default::default(),
            resources: Default::default(),
            routes: Default::default(),
            site_status: Default::default(),
            connection_resets: Default::default(),
            gateway_send_times: Default::default(),
            client_send_times: Default::default(),
            outbound_peer_authorizations: Default::default(),
            inbound_peer_authorizations: Default::default(),
            rejected_inbound_peer_authorizations: Default::default(),
        }
    }

    /// Initialize the [`ClientState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(
        self,
        upstream_do53: Vec<UpstreamDo53>,
        upstream_doh: Vec<UpstreamDoH>,
        search_domain: Option<DomainName>,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) -> SimClient {
        let mut client_state = ClientState::new(
            self.key.0,
            Default::default(),
            self.internet_resource_active,
            now,
            utc_now
                .signed_duration_since(DateTime::UNIX_EPOCH)
                .to_std()
                .unwrap(),
        ); // Cheating a bit here by reusing the key as seed.
        client_state.update_interface_config(Interface {
            ipv4: self.tunnel_ip4,
            ipv6: self.tunnel_ip6,
            upstream_dns: Vec::new(),
            upstream_do53,
            upstream_doh,
            search_domain,
        });
        client_state.update_system_resolvers(self.system_dns_resolvers);

        SimClient::new(
            self.id,
            client_state,
            self.malicious_behaviour,
            self.os,
            now,
        )
    }

    pub(crate) fn disconnect_resource(&mut self, resource: &ResourceId) {
        for _ in self.routes.extract_if(.., |(r, _)| r == resource) {}

        self.discard_authorization(resource);
        self.dns_resource_resolutions
            .retain(|(candidate, _), _| candidate != resource);

        let site = match self.site_for_resource(*resource) {
            Ok(site) => site,
            Err(SiteLookupError::ResourceHasNoSite) => return,
            Err(SiteLookupError::ResourceNotFound) => {
                tracing::error!(%resource, "No site for resource");
                return;
            }
        };

        // If this was the last resource we were connected to for this site,
        // the connection will be GC'd.
        if self
            .connected_resources()
            .all(|r| self.site_for_resource(r).is_ok_and(|s| s != site))
        {
            tracing::debug!(
                last_resource = %resource,
                site = %site.id,
                "We are no longer connected to any resources in this site"
            );

            self.site_status.remove(&site.id);
        }
    }

    pub(crate) fn set_internet_resource_state(&mut self, active: bool) {
        let resource = self
            .resources
            .iter()
            .find(|r| matches!(r, Resource::Internet(_)));

        self.internet_resource_active = active;

        let Some(resource) = resource else {
            return;
        };

        if active {
            self.routes
                .push((resource.id(), Ipv4Network::DEFAULT_ROUTE.into()));
            self.routes
                .push((resource.id(), Ipv6Network::DEFAULT_ROUTE.into()));
        } else {
            self.disconnect_resource(&resource.id());
        }
    }

    pub(crate) fn remove_resource(&mut self, resource: &ResourceId) {
        self.disconnect_resource(resource);

        if self.internet_resource().is_some_and(|r| r == *resource) {
            self.internet_resource_active = false;
        }

        self.resources.retain(|r| r.id() != *resource);
        self.remove_pool_authorizations(*resource);
    }

    /// Records a pool through which `peer` may reach us.
    pub(crate) fn add_inbound_peer_pool(&mut self, peer: ClientId, pool: ResourceId) {
        self.inbound_peer_authorizations
            .entry(peer)
            .or_default()
            .insert(pool);
        if let Some(rejected) = self.rejected_inbound_peer_authorizations.get_mut(&peer) {
            rejected.remove(&pool);
        }
    }

    /// Drops a rejected pool in both directions for `peer`.
    pub(crate) fn reject_peer_pool(
        &mut self,
        peer: ClientId,
        pool: ResourceId,
        filters: Vec<Filter>,
    ) {
        remove_peer_pool(&mut self.outbound_peer_authorizations, peer, pool);
        self.revoke_inbound_peer_pool(peer, pool, filters);
    }

    /// Expires the inbound authorization `peer` holds towards us through `pool`.
    pub(crate) fn revoke_inbound_peer_pool(
        &mut self,
        peer: ClientId,
        pool: ResourceId,
        filters: Vec<Filter>,
    ) {
        if !self
            .inbound_peer_authorizations
            .get(&peer)
            .is_some_and(|pools| pools.contains(&pool))
        {
            return;
        }

        remove_peer_pool(&mut self.inbound_peer_authorizations, peer, pool);
        self.rejected_inbound_peer_authorizations
            .entry(peer)
            .or_default()
            .insert(pool, filters);
    }

    pub(crate) fn rejected_inbound_peer_filter_allows(
        &self,
        peer: ClientId,
        protocol: Protocol,
    ) -> bool {
        self.rejected_inbound_peer_authorizations
            .get(&peer)
            .is_some_and(|pools| {
                pools
                    .values()
                    .any(|filters| protocol_filter_allows(filters, protocol))
            })
    }

    /// Whether we hold any authorization at all for `peer` to reach us.
    pub(crate) fn has_inbound_peer_authorization(&self, peer: ClientId) -> bool {
        self.inbound_peer_authorizations
            .get(&peer)
            .is_some_and(|pools| !pools.is_empty())
    }

    pub(crate) fn inbound_peer_pools(
        &self,
    ) -> impl Iterator<Item = (ClientId, BTreeSet<ResourceId>)> + '_ {
        self.inbound_peer_authorizations
            .iter()
            .map(|(peer, pools)| (*peer, pools.clone()))
    }

    /// Drops all active authorizations through `pool`.
    fn remove_pool_authorizations(&mut self, pool: ResourceId) {
        remove_pool(&mut self.outbound_peer_authorizations, pool);
        remove_pool(&mut self.inbound_peer_authorizations, pool);
    }

    /// Drops every authorization involving `peer`, as the connection to it is gone.
    pub(crate) fn forget_peer_authorizations(&mut self, peer: ClientId) {
        self.outbound_peer_authorizations.remove(&peer);
        self.inbound_peer_authorizations.remove(&peer);
        self.rejected_inbound_peer_authorizations.remove(&peer);
    }

    /// Checks whether any active inbound authorization from `peer` permits `protocol`.
    pub(crate) fn inbound_peer_filter_allows(&self, peer: ClientId, protocol: Protocol) -> bool {
        self.inbound_peer_authorizations
            .get(&peer)
            .is_some_and(|pools| {
                pools
                    .iter()
                    .any(|pool| self.strict_resource_filter_allows(*pool, protocol))
            })
    }

    pub(crate) fn authorized_pools_towards(
        &self,
        peer: ClientId,
    ) -> impl Iterator<Item = ResourceId> + '_ {
        self.outbound_peer_authorizations
            .get(&peer)
            .into_iter()
            .flatten()
            .copied()
    }

    pub(crate) fn record_outbound_peer_authorization(&mut self, peer: ClientId, pool: ResourceId) {
        self.outbound_peer_authorizations
            .entry(peer)
            .or_default()
            .insert(pool);
    }

    pub(crate) fn candidate_pools(&self, protocol: Protocol) -> Vec<ResourceId> {
        self.device_pool_ids()
            .into_iter()
            .filter(|pool| self.resource_filter_allows(*pool, protocol))
            .sorted_by_key(|pool| {
                (
                    filter_breadth(self.pool_filters(*pool).unwrap()),
                    std::cmp::Reverse(*pool),
                )
            })
            .collect()
    }

    /// The device pools this client holds, by id.
    pub(crate) fn device_pool_ids(&self) -> Vec<ResourceId> {
        self.resources
            .iter()
            .filter_map(|r| match r {
                Resource::DevicePool(pool) => Some(pool.id),
                Resource::Dns(_) => None,
                Resource::Cidr(_) => None,
                Resource::Internet(_) => None,
            })
            .sorted()
            .collect()
    }

    fn pool_filters(&self, pool: ResourceId) -> Option<&[Filter]> {
        self.resources.iter().find_map(|r| match r {
            Resource::DevicePool(p) if p.id == pool => Some(p.filters.as_slice()),
            Resource::DevicePool(_) => None,
            Resource::Dns(_) => None,
            Resource::Cidr(_) => None,
            Resource::Internet(_) => None,
        })
    }

    pub(crate) fn update_resource_metadata(&mut self, resource: Resource) {
        let existing = self
            .resources
            .iter_mut()
            .find(|existing| existing.id() == resource.id())
            .expect("an edited resource must exist on the client");

        *existing = resource;
    }

    pub(crate) fn connected_resources(&self) -> impl Iterator<Item = ResourceId> + '_ {
        iter::empty()
            .chain(self.connected_cidr_resources.clone())
            .chain(self.connected_dns_resources.clone())
            .chain(
                self.connected_internet_resource
                    .then(|| self.internet_resource())
                    .flatten(),
            )
    }

    pub(crate) fn restart(&mut self, key: PrivateKey, now: Instant) {
        self.routes.clear();

        self.key = key;

        self.reset_connections(now);
        self.readd_all_resources();
    }

    /// Resets the connections to the given gateways, as if only they had disconnected.
    ///
    /// Resources served by other gateways stay connected.
    pub(crate) fn reset_connections_to_gateways(
        &mut self,
        gateways: &BTreeSet<GatewayId>,
        gateway_for_resource: impl Fn(ResourceId) -> Option<GatewayId>,
        now: Instant,
    ) {
        let is_affected =
            |rid: &ResourceId| gateway_for_resource(*rid).is_some_and(|g| gateways.contains(&g));

        for gateway in gateways {
            self.gateway_send_times.remove(gateway);
        }

        let mut affected = self
            .connected_cidr_resources
            .iter()
            .chain(self.connected_dns_resources.iter())
            .copied()
            .filter(is_affected)
            .collect::<Vec<_>>();

        if self.connected_internet_resource
            && let Some(internet) = self.internet_resource()
            && is_affected(&internet)
        {
            affected.push(internet);
        }

        if affected.is_empty() {
            return;
        }

        self.connection_resets.push(now);
        self.discard_connections(affected);
    }

    /// The Gateway closed the connection, so everything we reached through it is gone.
    ///
    /// Only the connection to that Gateway goes; the ICE state towards our peers, which
    /// `connection_resets` tracks, is untouched.
    pub(crate) fn close_gateway_connection(
        &mut self,
        gateway: GatewayId,
        resources: &BTreeSet<ResourceId>,
    ) {
        self.gateway_send_times.remove(&gateway);

        let connected = self.connected_resources().collect::<BTreeSet<_>>();
        let affected = resources
            .iter()
            .copied()
            .filter(|resource| connected.contains(resource))
            .collect();

        self.discard_connections(affected);
    }

    fn discard_connections(&mut self, affected: Vec<ResourceId>) {
        for resource in affected {
            self.discard_authorization(&resource);
            self.dns_resource_resolutions
                .retain(|(candidate, _), _| *candidate != resource);

            if let Ok(site) = self.site_for_resource(resource)
                && let Some(status) = self.site_status.get_mut(&site.id)
            {
                *status = ResourceStatus::Unknown;
            }
        }
    }

    pub(crate) fn reset_connections(&mut self, now: Instant) {
        self.connection_resets.push(now);

        // A reset tears the connection down; a subsequent packet re-establishes it
        // (buffered, then sent) rather than hitting a dead WireGuard session, so the
        // idle history that drives the re-key tolerance must start fresh.
        self.gateway_send_times.clear();
        self.client_send_times.clear();

        self.connected_cidr_resources.clear();
        self.connected_dns_resources.clear();
        self.dns_resource_resolutions.clear();
        self.connected_internet_resource = false;
        // Peer authorizations in both directions go with their connections.
        self.outbound_peer_authorizations.clear();
        self.inbound_peer_authorizations.clear();
        self.rejected_inbound_peer_authorizations.clear();

        for status in self.site_status.values_mut() {
            *status = ResourceStatus::Unknown;
        }
    }

    pub(crate) fn add_internet_resource(&mut self, resource: InternetResource) {
        self.resources.push(Resource::Internet(resource.clone()));

        if self.internet_resource_active {
            self.routes
                .push((resource.id, Ipv4Network::DEFAULT_ROUTE.into()));
            self.routes
                .push((resource.id, Ipv6Network::DEFAULT_ROUTE.into()));
        }
    }

    pub(crate) fn add_cidr_resource(&mut self, r: CidrResource) {
        let address = r.address;
        let r = Resource::Cidr(r);
        let rid = r.id();

        if let Some(existing) = self.resources.iter().find(|existing| existing.id() == rid)
            && !matches!(classify(existing, &r), EditEffect::Metadata)
        {
            self.remove_resource(&existing.id());
        }

        self.resources.push(r);
        self.routes.push((rid, address));

        if self.expected_tcp_connections.values().contains(&rid) {
            self.set_resource_online(rid);
        }
    }

    pub(crate) fn add_dns_resource(&mut self, r: DnsResource) {
        let r = Resource::Dns(r);
        let rid = r.id();

        if let Some(existing) = self.resources.iter().find(|existing| existing.id() == rid)
            && !matches!(classify(existing, &r), EditEffect::Metadata)
        {
            self.remove_resource(&existing.id());
        }

        self.resources.push(r);

        if self.expected_tcp_connections.values().contains(&rid) {
            self.set_resource_online(rid);
        }
    }

    pub(crate) fn add_device_pool_resource(&mut self, r: DevicePoolResource) {
        let r = Resource::DevicePool(r);
        let rid = r.id();

        match self
            .resources
            .iter()
            .position(|existing| existing.id() == rid)
        {
            // A filter change keeps the pool's authorizations: the client updates its routes in place.
            Some(index) => self.resources[index] = r,
            None => self.resources.push(r),
        }
    }

    /// Re-adds all resources in the order they have been initially added.
    pub(crate) fn readd_all_resources(&mut self) {
        for resource in mem::take(&mut self.resources) {
            match resource {
                Resource::Dns(d) => self.add_dns_resource(d),
                Resource::Cidr(c) => self.add_cidr_resource(c),
                Resource::Internet(i) => self.add_internet_resource(i),
                Resource::DevicePool(d) => self.add_device_pool_resource(d),
            }
        }
    }

    pub(crate) fn expected_resources(&self) -> Vec<ResourceView> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|resource| {
                let status = self.expected_resource_status(&resource);

                resource.into_view(status)
            })
            .sorted()
            .collect()
    }

    fn expected_resource_status(&self, resource: &Resource) -> ResourceStatus {
        let sites = resource.sites();

        if sites.is_empty() {
            return ResourceStatus::Unknown;
        }

        if sites.iter().any(|site| {
            self.site_status
                .get(&site.id)
                .is_some_and(|status| *status == ResourceStatus::Online)
        }) {
            return ResourceStatus::Online;
        }

        if sites.iter().all(|site| {
            self.site_status
                .get(&site.id)
                .is_some_and(|status| *status == ResourceStatus::Offline)
        }) {
            return ResourceStatus::Offline;
        }

        ResourceStatus::Unknown
    }

    /// Returns the list of resources where we are not "sure" whether they are online or unknown.
    ///
    /// Resources with TCP connections have an automatic retry and therefore, modelling their exact online/unknown state is difficult.
    pub(crate) fn maybe_online_resources(&self) -> BTreeSet<ResourceId> {
        let resources_with_tcp_connections = self
            .expected_tcp_connections
            .values()
            .copied()
            .collect::<BTreeSet<_>>();

        let maybe_online_sites = resources_with_tcp_connections
            .into_iter()
            .filter_map(|r| self.site_for_resource(r).ok())
            .collect::<BTreeSet<_>>();

        self.resources
            .iter()
            .filter_map(move |r| {
                let site = r.site().ok()?;
                maybe_online_sites.contains(site).then_some(r.id())
            })
            .collect()
    }

    pub(crate) fn tunnel_ip_for(&self, dst: IpAddr) -> IpAddr {
        match dst {
            IpAddr::V4(_) => self.tunnel_ip4.into(),
            IpAddr::V6(_) => self.tunnel_ip6.into(),
        }
    }

    pub(crate) fn note_sent(&mut self, remote: Option<Remote>, now: Instant) {
        match remote {
            Some(Remote::Gateway(gateway)) => {
                self.gateway_send_times
                    .entry(gateway)
                    .or_default()
                    .insert(now);
            }
            Some(Remote::Client(client)) => {
                self.client_send_times
                    .entry(client)
                    .or_default()
                    .insert(now);
            }
            None => {}
        }
    }

    pub(crate) fn expect_tcp_outcome(
        &mut self,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        outcome: ExpectedOutcome,
    ) {
        match outcome {
            ExpectedOutcome::Dropped => {}
            ExpectedOutcome::RoundTripCompleted(Route::Resource { resource, .. }) => {
                self.expected_tcp_connections
                    .insert((src, dst, sport, dport), resource);
            }
            ExpectedOutcome::RoundTripCompleted(Route::Gateway(_)) => {}
            ExpectedOutcome::RoundTripCompleted(Route::Peer(_)) => {}
            ExpectedOutcome::Rejected { response, .. } => {
                self.expected_tcp_rejections
                    .insert((sport, dport), response);
            }
        }
    }

    pub(crate) fn connected_cidr_resources_allowing(
        &self,
        ip: IpAddr,
        protocol: Protocol,
    ) -> impl Iterator<Item = ResourceId> + '_ {
        self.resources.iter().filter_map(move |resource| {
            let Resource::Cidr(cidr) = resource else {
                return None;
            };
            let allows = self.connected_cidr_resources.contains(&cidr.id)
                && cidr.address.contains(ip)
                && protocol_filter_allows(&cidr.filters, protocol);

            allows.then_some(cidr.id)
        })
    }

    pub(crate) fn connect_to_resource(&mut self, resource: ResourceId, destination: Destination) {
        match destination {
            Destination::DomainName { .. } => {
                self.connected_dns_resources.insert(resource);
            }
            Destination::IpAddr(_) => self.connect_to_internet_or_cidr_resource(resource),
        }

        self.set_resource_online(resource);
    }

    /// The client no longer holds an authorization for `resource`; the next packet requests a new one.
    fn discard_authorization(&mut self, resource: &ResourceId) {
        self.connected_cidr_resources.remove(resource);
        self.connected_dns_resources.remove(resource);

        if self.internet_resource().is_some_and(|r| r == *resource) {
            self.connected_internet_resource = false;
        }
    }

    fn set_resource_online(&mut self, rid: ResourceId) {
        let site = match self.site_for_resource(rid) {
            Ok(site) => site,
            Err(SiteLookupError::ResourceHasNoSite) => return,
            Err(SiteLookupError::ResourceNotFound) => {
                tracing::error!(%rid, "Unknown resource or multi-site resource");
                return;
            }
        };

        let previous = self.site_status.insert(site.id, ResourceStatus::Online);

        if previous.is_none_or(|s| s != ResourceStatus::Online) {
            tracing::debug!(%rid, sid = %site.id, "Resource is now online");
        }
    }

    fn connect_to_internet_or_cidr_resource(&mut self, rid: ResourceId) {
        if self.internet_resource_active
            && let Some(internet) = self.internet_resource()
            && internet == rid
        {
            self.connected_internet_resource = true;
            return;
        }

        if self.resources.iter().any(|r| r.id() == rid) {
            let is_new = self.connected_cidr_resources.insert(rid);

            if is_new {
                tracing::debug!(%rid, "Now connected to CIDR resource");
            }
        }
    }

    pub(crate) fn on_dns_query(
        &mut self,
        query: &DnsQuery,
        upstream_do53: &[UpstreamDo53],
        global_dns_records: &DnsRecords,
        icmp_error_hosts: &IcmpErrorHosts,
    ) {
        if self.is_device_dns_query(query) {
            self.expect_dns_response(query);
            return;
        }

        if let Some(resource) = self.is_site_specific_dns_query(query) {
            self.prepare_dns_resource_connection(resource, global_dns_records);
            self.set_resource_online(resource);
            self.connected_dns_resources.insert(resource);
            self.expect_dns_response(query);

            return;
        }

        if self.is_local_dns_resource_query(query)
            && matches!(query.r_type, RecordType::A | RecordType::AAAA)
        {
            let record_types = global_dns_records.domain_rtypes(&query.domain);
            for ((_, domain), records) in &mut self.dns_resource_resolutions {
                if domain == &query.domain {
                    *records = record_types.clone();
                }
            }
        }

        if self.is_local_dns_resource_query(query)
            && !self.local_dns_resource_query_has_records(query)
        {
            self.expect_dns_handshake(&query.dns_server, query.query_id, query.transport);
            return;
        }

        if self.local_dns_resource(query).is_some() {
            self.expect_dns_response(query);

            return;
        }

        if let Some(resource) = self.dns_query_via_resource(query, upstream_do53) {
            let proto = match query.transport {
                DnsTransport::Udp { .. } => Protocol::Udp(53),
                DnsTransport::Tcp => Protocol::Tcp(53),
            };

            if !self.resource_filter_allows(resource, proto) {
                tracing::debug!("Resource filter does not allow protocol, dropping");
                self.expect_dns_response(query); // We always generate a response, even if we don't connect to the upstream server.
                return;
            }

            if self.resolver_is_unreachable(query, icmp_error_hosts) {
                // The resolver answers with an ICMP error; connlib fails the query
                // and responds with SERVFAIL, so no records are learned.
                self.expect_dns_handshake(&query.dns_server, query.query_id, query.transport);
            } else {
                self.expect_dns_response(query);
            }

            self.connect_to_internet_or_cidr_resource(resource);
            self.set_resource_online(resource);

            return;
        }

        self.expect_dns_response(query);
    }

    pub(crate) fn on_dns_resource_ptr_query(
        &mut self,
        dns_server: &dns::Upstream,
        query_id: u16,
        transport: DnsTransport,
    ) {
        self.expect_dns_handshake(dns_server, query_id, transport);
    }

    /// Returns whether the query's resolver answers tunnelled traffic with ICMP errors.
    fn resolver_is_unreachable(&self, query: &DnsQuery, icmp_error_hosts: &IcmpErrorHosts) -> bool {
        match &query.dns_server {
            dns::Upstream::Do53 { server } => {
                icmp_error_hosts.icmp_error_for_ip(server.ip()).is_some()
            }
            dns::Upstream::DoH { .. } => false,
        }
    }

    fn expect_dns_response(&mut self, query: &DnsQuery) {
        self.dns_records
            .entry(query.domain.clone())
            .or_default()
            .insert(query.r_type);

        self.expect_dns_handshake(&query.dns_server, query.query_id, query.transport);
    }

    /// Expects a response for the query without learning any records from it, e.g. a SERVFAIL.
    fn expect_dns_handshake(
        &mut self,
        dns_server: &dns::Upstream,
        query_id: u16,
        transport: DnsTransport,
    ) {
        match transport {
            DnsTransport::Udp { local_port } => {
                self.expected_udp_dns_handshakes.push_back((
                    dns_server.clone(),
                    query_id,
                    local_port,
                ));
            }
            DnsTransport::Tcp => {
                self.expected_tcp_dns_handshakes
                    .push_back((dns_server.clone(), query_id));
            }
        }
    }

    fn is_device_dns_query(&self, query: &DnsQuery) -> bool {
        is_device_domain(&query.domain)
    }

    pub(crate) fn ipv4_cidr_resource_dsts(&self) -> Vec<(Ipv4Network, Vec<Filter>)> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_cidr())
            .filter_map(|c| match c.address {
                IpNetwork::V4(ipv4_network) => Some((ipv4_network, c.filters)),
                IpNetwork::V6(_) => None,
            })
            .collect()
    }

    pub(crate) fn ipv6_cidr_resource_dsts(&self) -> Vec<(Ipv6Network, Vec<Filter>)> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_cidr())
            .filter_map(|c| match c.address {
                IpNetwork::V6(ipv6_network) => Some((ipv6_network, c.filters)),
                IpNetwork::V4(_) => None,
            })
            .collect()
    }

    fn site_for_resource(&self, resource: ResourceId) -> Result<Site, SiteLookupError> {
        let r = self
            .resources
            .iter()
            .find(|r| r.id() == resource)
            .ok_or(SiteLookupError::ResourceNotFound)?;

        let sites = r.sites();
        if sites.is_empty() {
            return Err(SiteLookupError::ResourceHasNoSite);
        }

        Ok(r.site().expect("resources should only have 1 site").clone())
    }

    pub(crate) fn active_internet_resource(&self) -> Option<ResourceId> {
        self.internet_resource_active
            .then(|| self.internet_resource())
            .flatten()
    }

    pub(crate) fn resource_by_dst(
        &self,
        src: IpAddr,
        destination: &Destination,
        proto: Protocol,
    ) -> Option<ResourceId> {
        match destination {
            Destination::DomainName { name, .. } => {
                if let Some(r) = self.dns_resource_by_domain_and_proto(name, src, proto) {
                    return Some(r.id);
                }
            }
            Destination::IpAddr(addr) => {
                if let Some(id) = self.cidr_resource_by_ip_and_proto(*addr, proto) {
                    return Some(id);
                }
            }
        }

        self.active_internet_resource()
    }

    fn resource_filter_allows(&self, rid: ResourceId, proto: Protocol) -> bool {
        let Some(filters) = self
            .resources
            .iter()
            .find(|r| r.id() == rid)
            .map(|r| r.filters())
        else {
            return false;
        };
        self.filter_allows(filters, proto)
    }

    pub(crate) fn strict_resource_filter_allows(&self, rid: ResourceId, proto: Protocol) -> bool {
        self.resources
            .iter()
            .find(|r| r.id() == rid)
            .is_some_and(|r| protocol_filter_allows(r.filters(), proto))
    }

    /// Apply `filters` to `proto`, honoring the malicious-behaviour
    /// `ignore_resource_filters` bypass.
    fn filter_allows(&self, filters: &[tunnel_proto::messages::Filter], proto: Protocol) -> bool {
        if self.malicious_behaviour.ignore_resource_filters {
            return true;
        }

        protocol_filter_allows(filters, proto)
    }

    pub(crate) fn dns_resource_by_domain_and_proto(
        &self,
        domain: &DomainName,
        src: IpAddr,
        proto: Protocol,
    ) -> Option<DnsResource> {
        let mut candidates = self.dns_resources_by_domain(
            domain,
            |resource| resource.ip_stack.supports_ip(src),
            |resource| protocol_filter_allows(&resource.filters, proto),
        );
        candidates.sort_by(|left, right| {
            filter_breadth(&left.filters)
                .cmp(&filter_breadth(&right.filters))
                .then_with(|| {
                    dns::Pattern::new(&left.address)
                        .unwrap()
                        .cmp(&dns::Pattern::new(&right.address).unwrap())
                })
                .then_with(|| right.id.cmp(&left.id))
        });
        let ids = candidates
            .iter()
            .filter(|resource| self.filter_allows(&resource.filters, proto))
            .map(|resource| resource.id)
            .collect_vec();
        let selected = self
            .select_gateway_resource(&ids)
            .or_else(|| candidates.first().map(|r| r.id))?;
        candidates.into_iter().find(|r| r.id == selected)
    }

    pub(crate) fn dns_resource_by_domain(
        &self,
        domain: &DomainName,
        eligible: impl Fn(&DnsResource) -> bool,
        preferred: impl Fn(&DnsResource) -> bool,
    ) -> Option<DnsResource> {
        self.dns_resources_by_domain(domain, eligible, preferred)
            .into_iter()
            .next()
    }

    fn dns_resources_by_domain(
        &self,
        domain: &DomainName,
        eligible: impl Fn(&DnsResource) -> bool,
        preferred: impl Fn(&DnsResource) -> bool,
    ) -> Vec<DnsResource> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_dns())
            .filter(|r| dns::is_subdomain(domain, &r.address))
            .filter(|r| eligible(r))
            .sorted_by(|r1, r2| {
                let by_preference = match (preferred(r1), preferred(r2)) {
                    (true, true) => Ordering::Equal,
                    (false, false) => Ordering::Equal,
                    (true, false) => Ordering::Greater,
                    (false, true) => Ordering::Less,
                };
                let by_pattern = dns::Pattern::new(&r1.address)
                    .unwrap()
                    .cmp(&dns::Pattern::new(&r2.address).unwrap())
                    .reverse();
                let by_id = r1.id.cmp(&r2.id);

                by_preference.then(by_pattern).then(by_id).reverse()
            })
            .collect()
    }

    /// Prefers existing connections, then applies the portal's sampled candidate index.
    fn select_gateway_resource(&self, candidates: &[ResourceId]) -> Option<ResourceId> {
        if candidates.is_empty() {
            return None;
        }

        candidates
            .iter()
            .copied()
            .find(|candidate| self.connected_resources().any(|id| id == *candidate))
            .or_else(|| {
                candidates
                    .get(self.resource_selector as usize % candidates.len())
                    .copied()
            })
    }

    fn dns_resource_by_domain_for_records(
        &self,
        domain: &DomainName,
        has_a_record: bool,
        has_aaaa_record: bool,
    ) -> Option<ResourceId> {
        self.dns_resource_by_domain(
            domain,
            |resource| {
                (has_a_record && resource.ip_stack.supports_ipv4())
                    || (has_aaaa_record && resource.ip_stack.supports_ipv6())
            },
            |_| true,
        )
        .map(|resource| resource.id)
    }

    fn resolved_domains(&self) -> impl Iterator<Item = (DomainName, BTreeSet<RecordType>)> + '_ {
        self.dns_records
            .iter()
            .filter(|(domain, _)| {
                self.dns_resource_by_domain(domain, |_| true, |_| true)
                    .is_some()
            })
            .filter(|(domain, _)| !is_device_domain(domain))
            .map(|(domain, ips)| (domain.clone(), ips.clone()))
    }

    pub(crate) fn resolved_v4_domains(&self) -> Vec<(DomainName, Vec<Filter>)> {
        self.resolved_domains()
            .filter_map(|(domain, records)| {
                if !records.iter().any(|r| matches!(r, &RecordType::A)) {
                    return None;
                }
                let resource = self.dns_resource_by_domain(
                    &domain,
                    |resource| resource.ip_stack.supports_ipv4(),
                    |_| true,
                )?;

                Some((domain, resource.filters))
            })
            .collect()
    }

    pub(crate) fn resolved_v6_domains(&self) -> Vec<(DomainName, Vec<Filter>)> {
        self.resolved_domains()
            .filter_map(|(domain, records)| {
                if !records.iter().any(|r| matches!(r, &RecordType::AAAA)) {
                    return None;
                }
                let resource = self.dns_resource_by_domain(
                    &domain,
                    |resource| resource.ip_stack.supports_ipv6(),
                    |_| true,
                )?;

                Some((domain, resource.filters))
            })
            .collect()
    }

    /// Returns the DNS servers that we expect connlib to use.
    ///
    /// If there are upstream Do53 servers configured in the portal, it should use those.
    /// If there are no custom servers defined, it should use the DoH servers specified in the portal.
    /// Otherwise it should use whatever was configured on the system prior to connlib starting.
    ///
    /// This purposely returns a `Vec` so we also assert the order!
    pub(crate) fn expected_dns_servers(
        &self,
        upstream_do53: &[UpstreamDo53],
        upstream_doh: &[UpstreamDoH],
    ) -> Vec<dns::Upstream> {
        if !upstream_do53.is_empty() {
            return upstream_do53
                .iter()
                .map(|u| dns::Upstream::Do53 {
                    server: SocketAddr::new(u.ip, 53),
                })
                .collect();
        }

        if !upstream_doh.is_empty() {
            return upstream_doh
                .iter()
                .map(|u| dns::Upstream::DoH {
                    server: u.url.clone(),
                })
                .collect();
        }

        self.system_dns_resolvers
            .iter()
            .map(|ip| dns::Upstream::Do53 {
                server: SocketAddr::new(*ip, 53),
            })
            .collect()
    }

    pub(crate) fn expected_routes(&self) -> BTreeSet<IpNetwork> {
        iter::empty()
            .chain(self.routes.iter().map(|(_, r)| *r))
            .chain(default_routes_v4())
            .chain(default_routes_v6())
            .collect()
    }

    pub(crate) fn cidr_resource_by_ip_and_proto(
        &self,
        ip: IpAddr,
        proto: Protocol,
    ) -> Option<ResourceId> {
        let mut candidates =
            self.cidr_resources_by_ip(ip, |r| protocol_filter_allows(&r.filters, proto));
        candidates.sort_by(|left, right| {
            filter_breadth(&left.filters)
                .cmp(&filter_breadth(&right.filters))
                .then_with(|| right.address.netmask().cmp(&left.address.netmask()))
                .then_with(|| right.id.cmp(&left.id))
        });
        let ids = candidates
            .iter()
            .filter(|resource| self.filter_allows(&resource.filters, proto))
            .map(|resource| resource.id)
            .collect_vec();
        self.select_gateway_resource(&ids)
            .or_else(|| candidates.first().map(|r| r.id))
    }

    pub(crate) fn cidr_resource_by_ip(
        &self,
        ip: IpAddr,
        predicate: impl Fn(&CidrResource) -> bool,
    ) -> Option<ResourceId> {
        self.cidr_resources_by_ip(ip, predicate)
            .first()
            .map(|r| r.id)
    }

    fn cidr_resources_by_ip(
        &self,
        ip: IpAddr,
        predicate: impl Fn(&CidrResource) -> bool,
    ) -> Vec<CidrResource> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_cidr())
            .filter(|c| c.address.contains(ip))
            .sorted_by(|r1, r2| {
                let by_predicate = match (predicate(r1), predicate(r2)) {
                    (true, true) => Ordering::Equal,
                    (false, false) => Ordering::Equal,
                    (true, false) => Ordering::Greater,
                    (false, true) => Ordering::Less,
                };
                let by_netmask = r1.address.netmask().cmp(&r2.address.netmask());
                let by_id = r1.id.cmp(&r2.id);

                by_predicate.then(by_netmask).then(by_id).reverse()
            })
            .collect()
    }

    pub(crate) fn resolved_ip4_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
    ) -> Vec<Ipv4Addr> {
        self.resolved_ips_for_non_resources(global_dns_records)
            .filter_map(|ip| match ip {
                IpAddr::V4(v4) => Some(v4),
                IpAddr::V6(_) => None,
            })
            .collect()
    }

    pub(crate) fn resolved_ip6_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
    ) -> Vec<Ipv6Addr> {
        self.resolved_ips_for_non_resources(global_dns_records)
            .filter_map(|ip| match ip {
                IpAddr::V6(v6) => Some(v6),
                IpAddr::V4(_) => None,
            })
            .collect()
    }

    fn resolved_ips_for_non_resources<'a>(
        &'a self,
        global_dns_records: &'a DnsRecords,
    ) -> impl Iterator<Item = IpAddr> + 'a {
        self.dns_records
            .keys()
            .filter_map(move |domain| {
                self.dns_resource_by_domain(domain, |_| true, |_| true)
                    .is_none()
                    .then_some(global_dns_records.domain_ips_iter(domain))
            })
            .flatten()
    }

    /// Returns the resource we will forward the DNS query for the given name to.
    ///
    /// DNS servers may be resources, in which case queries that need to be forwarded actually need to be encapsulated.
    pub(crate) fn dns_query_via_resource(
        &self,
        query: &DnsQuery,
        upstream_do53: &[UpstreamDo53],
    ) -> Option<ResourceId> {
        // System resolvers are contacted outside the tunnel.
        if upstream_do53.is_empty() {
            return None;
        }

        self.upstream_dns_server_via_resource(&query.dns_server)?;
        let dns::Upstream::Do53 { server } = query.dns_server else {
            return None;
        };
        let protocol = match query.transport {
            DnsTransport::Udp { .. } => Protocol::Udp(server.port()),
            DnsTransport::Tcp => Protocol::Tcp(server.port()),
        };
        self.cidr_resource_by_ip_and_proto(server.ip(), protocol)
            .or_else(|| self.active_internet_resource())
    }

    fn is_local_dns_resource_query(&self, query: &DnsQuery) -> bool {
        let is_local_record = query.r_type == RecordType::A
            || query.r_type == RecordType::AAAA
            || query.r_type == RecordType::PTR;

        is_local_record
            && self
                .dns_resource_by_domain(&query.domain, |_| true, |_| true)
                .is_some()
    }

    fn local_dns_resource(&self, query: &DnsQuery) -> Option<ResourceId> {
        let is_local_record = query.r_type == RecordType::A
            || query.r_type == RecordType::AAAA
            || query.r_type == RecordType::PTR;

        is_local_record
            .then(|| {
                self.dns_resource_by_domain_for_records(
                    &query.domain,
                    query.r_type != RecordType::AAAA,
                    query.r_type != RecordType::A,
                )
            })
            .flatten()
    }

    pub(crate) fn prepare_dns_resource_connection(
        &mut self,
        resource: ResourceId,
        global_dns_records: &DnsRecords,
    ) {
        if self.connected_dns_resources.contains(&resource) {
            return;
        }

        let domains = self
            .resolved_domains()
            .filter(|(domain, records)| {
                self.dns_resource_serves(
                    resource,
                    domain,
                    records.contains(&RecordType::A),
                    records.contains(&RecordType::AAAA),
                )
            })
            .map(|(domain, _)| domain)
            .collect_vec();

        for domain in domains {
            let record_types = global_dns_records.domain_rtypes(&domain);
            self.dns_resource_resolutions
                .insert((resource, domain), record_types);
        }
    }

    /// Whether the DNS resource `resource` covers `domain` and can serve the records it has.
    ///
    /// The gateway resolves a domain for whichever resource the client connects through, which
    /// is chosen per packet by filter and need not be the one preferred for the records.
    fn dns_resource_serves(
        &self,
        resource: ResourceId,
        domain: &DomainName,
        has_a_record: bool,
        has_aaaa_record: bool,
    ) -> bool {
        self.resources
            .iter()
            .filter_map(|r| match r {
                Resource::Dns(dns) if dns.id == resource => Some(dns),
                Resource::Dns(_) => None,
                Resource::Cidr(_) => None,
                Resource::Internet(_) => None,
                Resource::DevicePool(_) => None,
            })
            .any(|dns| {
                dns::is_subdomain(domain, &dns.address)
                    && ((has_a_record && dns.ip_stack.supports_ipv4())
                        || (has_aaaa_record && dns.ip_stack.supports_ipv6()))
            })
    }

    pub(crate) fn dns_resource_resolution(
        &self,
        resource: ResourceId,
        domain: &DomainName,
    ) -> Option<&BTreeSet<RecordType>> {
        self.dns_resource_resolutions
            .get(&(resource, domain.clone()))
    }

    fn local_dns_resource_query_has_records(&self, query: &DnsQuery) -> bool {
        self.resources
            .iter()
            .filter_map(|resource| {
                let Resource::Dns(resource) = resource else {
                    return None;
                };

                dns::is_subdomain(&query.domain, &resource.address).then_some(resource)
            })
            .any(|resource| {
                (query.r_type != RecordType::A || resource.ip_stack.supports_ipv4())
                    && (query.r_type != RecordType::AAAA || resource.ip_stack.supports_ipv6())
            })
    }

    pub(crate) fn upstream_dns_server_via_resource(
        &self,
        upstream: &dns::Upstream,
    ) -> Option<ResourceId> {
        // TODO: Verify if we ever generate something that is not port 53 here.
        let server = match upstream {
            dns::Upstream::Do53 { server } => server,
            dns::Upstream::DoH { .. } => return None,
        };

        let maybe_active_cidr_resource = self.cidr_resource_by_ip(server.ip(), |r| {
            protocol_filter_allows(&r.filters, Protocol::Udp(53))
                && protocol_filter_allows(&r.filters, Protocol::Tcp(53))
        });
        let maybe_active_internet_resource = self.active_internet_resource();

        maybe_active_cidr_resource.or(maybe_active_internet_resource)
    }

    pub(crate) fn is_site_specific_dns_query(&self, query: &DnsQuery) -> Option<ResourceId> {
        let is_site_specific_record =
            query.r_type == RecordType::SRV || query.r_type == RecordType::TXT;

        if !is_site_specific_record {
            return None;
        }

        let candidates = self
            .dns_resources_by_domain(&query.domain, |_| true, |_| true)
            .into_iter()
            .map(|r| r.id)
            .collect_vec();
        self.select_gateway_resource(&candidates)
    }

    pub(crate) fn all_resource_ids(&self) -> Vec<ResourceId> {
        self.resources.iter().map(|r| r.id()).collect()
    }

    pub(crate) fn has_resource(&self, resource_id: ResourceId) -> bool {
        self.resources.iter().any(|r| r.id() == resource_id)
    }

    pub(crate) fn all_resources(&self) -> Vec<Resource> {
        self.resources.clone()
    }

    pub(crate) fn resource_descriptions(
        &self,
    ) -> Vec<tunnel_proto::messages::client::ResourceDescription> {
        self.resources
            .iter()
            .cloned()
            .map(Resource::into_description)
            .collect()
    }

    pub(crate) fn internet_resource(&self) -> Option<ResourceId> {
        self.resources.iter().find_map(|r| match r {
            Resource::Dns(_) => None,
            Resource::Cidr(_) => None,
            Resource::DevicePool(_) => None,
            Resource::Internet(internet_resource) => Some(internet_resource.id),
        })
    }

    pub(crate) fn system_dns_resolvers(&self) -> Vec<IpAddr> {
        self.system_dns_resolvers.clone()
    }

    pub(crate) fn set_system_dns_resolvers(&mut self, servers: &[IpAddr]) {
        self.system_dns_resolvers = servers.to_vec();
    }

    pub(crate) fn tcp_connection_tuple_to_resource(
        &self,
        resource: ResourceId,
    ) -> Option<(SPort, DPort)> {
        self.expected_tcp_connections
            .iter()
            .find_map(|((_, _, sport, dport), res)| (resource == *res).then_some((*sport, *dport)))
    }

    pub(crate) fn last_packet_sent_to_gateway_before(
        &self,
        gateway: GatewayId,
        at: Instant,
    ) -> Option<Instant> {
        self.gateway_send_times
            .get(&gateway)?
            .range(..at)
            .next_back()
            .copied()
    }

    pub(crate) fn last_packet_sent_to_client_before(
        &self,
        client: ClientId,
        at: Instant,
    ) -> Option<Instant> {
        self.client_send_times
            .get(&client)?
            .range(..at)
            .next_back()
            .copied()
    }

    /// Checks whether the given instant falls within a time period T .. T + ICE_TIMEOUT where T marks every point in time where we reset all our connections.
    pub(crate) fn has_reset_connections_within_ice_timeout(&self, at: Instant) -> bool {
        let ice_timeout = Duration::from_millis(22_000); // TODO: Figure out why this isn't exactly ICE timeout but longer?

        self.connection_resets
            .iter()
            .copied()
            .any(|t| (t..t + ice_timeout).contains(&at))
    }

    pub(crate) fn clear_packets(&mut self) {
        self.expected_udp_dns_handshakes.clear();
        self.expected_tcp_dns_handshakes.clear();
        self.expected_tcp_connections.clear();
        self.expected_tcp_rejections.clear();
    }
}

fn remove_peer_pool(
    authorizations: &mut BTreeMap<ClientId, BTreeSet<ResourceId>>,
    peer: ClientId,
    pool: ResourceId,
) {
    let Some(pools) = authorizations.get_mut(&peer) else {
        return;
    };

    pools.remove(&pool);
    if pools.is_empty() {
        authorizations.remove(&peer);
    }
}

fn remove_pool(authorizations: &mut BTreeMap<ClientId, BTreeSet<ResourceId>>, pool: ResourceId) {
    for pools in authorizations.values_mut() {
        pools.remove(&pool);
    }
    for _ in authorizations.extract_if(.., |_, pools| pools.is_empty()) {}
}

/// Applies the reference model's independent interpretation of resource filters.
/// Whether the SUT answers `domain` from the portal instead of DNS.
///
/// Device names resolve ahead of DNS resources, so a name matching both is answered
/// from the portal and never resolves to a resource's proxy IPs.
fn is_device_domain(domain: &DomainName) -> bool {
    dns::device_slug(domain).is_some()
}

pub(crate) fn protocol_filter_allows(filters: &[Filter], protocol: Protocol) -> bool {
    match protocol {
        Protocol::Tcp(port) => tcp_filter_allows(filters, port),
        Protocol::Udp(port) => udp_filter_allows(filters, port),
        Protocol::IcmpEcho(_) => icmp_filter_allows(filters),
    }
}

fn filter_breadth(filters: &[Filter]) -> u32 {
    if filters.is_empty() {
        return u32::MAX;
    }

    let count_ports = |extract: fn(&Filter) -> Option<(u16, u16)>| {
        let mut ranges = filters.iter().filter_map(extract).collect_vec();
        ranges.sort_unstable();

        let mut next = 0u32;
        let mut count = 0u32;
        for (start, end) in ranges {
            let first = u32::from(start).max(next);
            let end = u32::from(end);
            if first <= end {
                count += end - first + 1;
                next = end + 1;
            }
        }
        count
    };

    count_ports(|filter| match filter {
        Filter::Tcp(range) => Some((range.start(), range.end())),
        Filter::Udp(_) | Filter::Icmp => None,
    }) + count_ports(|filter| match filter {
        Filter::Udp(range) => Some((range.start(), range.end())),
        Filter::Tcp(_) | Filter::Icmp => None,
    }) + u32::from(filters.iter().any(|filter| matches!(filter, Filter::Icmp)))
}

/// Checks if a set of [`Filter`]s allows the given TCP port.
fn tcp_filter_allows(filters: &[Filter], dport: u16) -> bool {
    filters.is_empty()
        || filters.iter().any(|filter| match filter {
            Filter::Tcp(range) => range.as_range().contains(&dport),
            Filter::Icmp => false,
            Filter::Udp(_) => false,
        })
}

/// Checks if a set of [`Filter`]s allows ICMP traffic.
fn icmp_filter_allows(filters: &[Filter]) -> bool {
    filters.is_empty() || filters.iter().any(|f| matches!(f, Filter::Icmp))
}

/// Checks if a set of [`Filter`]s allows the given UDP port.
fn udp_filter_allows(filters: &[Filter], dport: u16) -> bool {
    filters.is_empty()
        || filters.iter().any(|filter| match filter {
            Filter::Udp(range) => range.as_range().contains(&dport),
            Filter::Icmp => false,
            Filter::Tcp(_) => false,
        })
}

impl ExecMutScope for RefClient {
    type Guard = ();

    fn enter(&self) -> Self::Guard {}
}

pub(crate) fn internet_resource_rejects(addr: IpAddr) -> bool {
    match addr {
        IpAddr::V4(addr) => {
            addr.is_private()
                || addr.is_loopback()
                || addr.is_link_local()
                || is_cgnat(addr)
                || addr.is_multicast()
                || is_reserved(addr)
        }
        IpAddr::V6(addr) => {
            addr.is_loopback()
                || addr.to_ipv4_mapped().is_some()
                || addr.is_unique_local()
                || addr.is_unicast_link_local()
                || addr.is_multicast()
        }
    }
}

fn is_cgnat(addr: Ipv4Addr) -> bool {
    matches!(addr.octets(), [100, 64..=127, _, _])
}

fn is_reserved(addr: Ipv4Addr) -> bool {
    matches!(addr.octets(), [240..=255, _, _, _])
}

pub(crate) fn is_resource_proxy(addr: IpAddr) -> bool {
    match addr {
        IpAddr::V4(addr) => tunnel_proto::IPV4_RESOURCES.contains(addr),
        IpAddr::V6(addr) => tunnel_proto::IPV6_RESOURCES.contains(addr),
    }
}

fn default_routes_v4() -> Vec<IpNetwork> {
    vec![
        IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11).unwrap()),
        IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(100, 96, 0, 0), 11).unwrap()),
        IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(100, 100, 111, 0), 24).unwrap()),
    ]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SiteLookupError {
    /// Resource does not exist for this client.
    ResourceNotFound,
    /// Resource exists but has no site by design (e.g. device pool resources).
    ResourceHasNoSite,
}

fn default_routes_v6() -> Vec<IpNetwork> {
    vec![
        IpNetwork::V6(
            Ipv6Network::new(Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0), 107).unwrap(),
        ),
        IpNetwork::V6(
            Ipv6Network::new(
                Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0, 0, 0, 0),
                107,
            )
            .unwrap(),
        ),
        IpNetwork::V6(
            Ipv6Network::new(
                Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0x0100, 0x0100, 0x0111, 0),
                120,
            )
            .unwrap(),
        ),
    ]
}
