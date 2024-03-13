use crate::ip_packet::{IpPacket, MutableIpPacket};
use crate::peer::PacketTransformClient;
use crate::peer_store::PeerStore;
use crate::{dns, dns::DnsQuery, Event, Tunnel, DNS_QUERIES_QUEUE_SIZE};
use bimap::BiMap;
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::{
    DnsServer, GatewayId, Interface as InterfaceConfig, IpDnsServer, ResourceDescription,
    ResourceDescriptionCidr, ResourceDescriptionDns, ResourceId, ReuseConnection,
};
use connlib_shared::{Callbacks, Dname, IpProvider};
use domain::base::Rtype;
use futures_bounded::FuturesTupleSet;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use itertools::Itertools;
use snownet::Client;

use hickory_resolver::config::{NameServerConfig, Protocol, ResolverConfig};
use hickory_resolver::TokioAsyncResolver;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet, VecDeque};
use std::iter;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::str::FromStr;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::time::{Interval, MissedTickBehavior};

// Using str here because Ipv4/6Network doesn't support `const` 🙃
const IPV4_RESOURCES: &str = "100.96.0.0/11";
const IPV6_RESOURCES: &str = "fd00:2021:1111:8000::/107";

const DNS_PORT: u16 = 53;
const DNS_SENTINELS_V4: &str = "100.100.111.0/24";
const DNS_SENTINELS_V6: &str = "fd00:2021:1111:8000:100:100:111:0/120";

#[derive(Debug, Clone, Hash, PartialEq, Eq)]
pub struct DnsResource {
    pub id: ResourceId,
    pub address: Dname,
}

impl DnsResource {
    pub fn from_description(description: &ResourceDescriptionDns, address: Dname) -> DnsResource {
        DnsResource {
            id: description.id,
            address,
        }
    }
}

impl<CB> Tunnel<CB, ClientState, Client, GatewayId>
where
    CB: Callbacks + 'static,
{
    /// Adds a the given resource to the tunnel.
    ///
    /// Once added, when a packet for the resource is intercepted a new data channel will be created
    /// and packets will be wrapped with wireguard and sent through it.
    pub fn add_resources(
        &mut self,
        resources: &[ResourceDescription],
    ) -> connlib_shared::Result<()> {
        for resource_description in resources {
            if let Some(resource) = self.role_state.resource_ids.get(&resource_description.id()) {
                if resource.has_different_address(resource) {
                    self.remove_resource(resource.id());
                }
            }

            match &resource_description {
                ResourceDescription::Dns(dns) => {
                    self.role_state
                        .dns_resources
                        .insert(dns.address.clone(), dns.clone());
                }
                ResourceDescription::Cidr(cidr) => {
                    self.role_state
                        .cidr_resources
                        .insert(cidr.address, cidr.clone());
                }
            }

            self.role_state
                .resource_ids
                .insert(resource_description.id(), resource_description.clone());
        }

        self.update_resource_list()?;
        self.update_routes()?;

        Ok(())
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%id))]
    pub fn remove_resource(&mut self, id: ResourceId) {
        self.role_state.awaiting_connection.remove(&id);
        self.role_state
            .dns_resources_internal_ips
            .retain(|r, _| r.id != id);
        self.role_state.dns_resources.retain(|_, r| r.id != id);
        self.role_state.cidr_resources.retain(|_, r| r.id != id);
        self.role_state
            .deferred_dns_queries
            .retain(|(r, _), _| r.id != id);

        self.role_state.resource_ids.remove(&id);

        if let Err(err) = self.update_routes() {
            tracing::error!(%id, "Failed to update routes: {err:?}");
        }

        if let Err(err) = self.update_resource_list() {
            tracing::error!("Failed to update resource list: {err:#?}")
        }

        let Some(gateway_id) = self.role_state.resources_gateways.remove(&id) else {
            tracing::debug!("No gateway associated with resource");
            return;
        };

        let Some(peer) = self.role_state.peers.get_mut(&gateway_id) else {
            return;
        };

        // First we remove the id from all allowed ips
        for (network, resources) in peer
            .allowed_ips
            .iter_mut()
            .filter(|(_, resources)| resources.contains(&id))
        {
            resources.remove(&id);

            if !resources.is_empty() {
                continue;
            }

            // If the allowed_ips doesn't correspond to any resource anymore we
            // clean up any related translation.
            peer.transform
                .translations
                .remove_by_left(&network.network_address());
        }

        // We remove all empty allowed ips entry since there's no resource that corresponds to it
        peer.allowed_ips.retain(|_, r| !r.is_empty());

        // If there's no allowed ip left we remove the whole peer because there's no point on keeping it around
        if peer.allowed_ips.is_empty() {
            self.role_state.peers.remove(&gateway_id);
            // TODO: should we have a Node::remove_connection?
        }

        tracing::debug!("Resource removed")
    }

    fn update_resource_list(&self) -> connlib_shared::Result<()> {
        self.callbacks.on_update_resources(
            self.role_state
                .resource_ids
                .values()
                .sorted()
                .cloned()
                .collect_vec(),
        )?;
        Ok(())
    }

    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&mut self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        self.role_state.interface_config = Some(config.clone());
        let effective_dns_servers = effective_dns_servers(
            config.upstream_dns.clone(),
            self.callbacks()
                .get_system_default_resolvers()
                .ok()
                .flatten()
                .unwrap_or_default(),
        );

        let dns_mapping = sentinel_dns_mapping(&effective_dns_servers);
        self.role_state.set_dns_mapping(dns_mapping.clone());

        self.device.initialize(
            config,
            // We can just sort in here because sentinel ips are created in order
            dns_mapping.left_values().copied().sorted().collect(),
            &self.callbacks().clone(),
        )?;

        self.device
            .set_routes(self.role_state.routes().collect(), &self.callbacks)?;
        let name = self.device.name().to_owned();

        self.callbacks.on_tunnel_ready()?;

        tracing::debug!(ip4 = %config.ipv4, ip6 = %config.ipv6, %name, "TUN device initialized");

        Ok(())
    }

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&mut self, id: ResourceId) {
        self.role_state.on_connection_failed(id);
        // self.peer_connections.lock().remove(&id.into());
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn update_routes(&mut self) -> connlib_shared::Result<()> {
        self.device
            .set_routes(self.role_state.routes().collect(), &self.callbacks)?;

        Ok(())
    }

    pub fn add_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String) {
        self.connections_state
            .node
            .add_remote_candidate(conn_id, ice_candidate, Instant::now());
    }
}

/// [`Tunnel`] state specific to clients.
pub struct ClientState {
    awaiting_connection: HashMap<ResourceId, AwaitingConnectionDetails>,
    resources_gateways: HashMap<ResourceId, GatewayId>,

    pub dns_resources_internal_ips: HashMap<DnsResource, HashSet<IpAddr>>,
    dns_resources: HashMap<String, ResourceDescriptionDns>,
    cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    pub resource_ids: HashMap<ResourceId, ResourceDescription>,
    pub deferred_dns_queries: HashMap<(DnsResource, Rtype), IpPacket<'static>>,

    pub peers: PeerStore<GatewayId, PacketTransformClient, HashSet<ResourceId>>,

    forwarded_dns_queries: FuturesTupleSet<
        Result<hickory_resolver::lookup::Lookup, hickory_resolver::error::ResolveError>,
        DnsQuery<'static>,
    >,

    pub ip_provider: IpProvider,

    refresh_dns_timer: Interval,

    dns_mapping: BiMap<IpAddr, DnsServer>,
    dns_resolvers: HashMap<IpAddr, TokioAsyncResolver>,

    buffered_events: VecDeque<Event<GatewayId>>,
    interface_config: Option<InterfaceConfig>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AwaitingConnectionDetails {
    pub domain: Option<Dname>,
    gateways: HashSet<GatewayId>,
    pub last_intent_sent_at: Instant,
}

impl ClientState {
    pub(crate) fn encapsulate<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
        now: Instant,
    ) -> Option<(GatewayId, MutableIpPacket<'a>)> {
        let (packet, dest) = match self.handle_dns(packet, now) {
            Ok(response) => {
                self.buffered_events
                    .push_back(Event::SendPacket(response?.to_owned()));
                return None;
            }
            Err(non_dns_packet) => non_dns_packet,
        };

        let Some(peer) = self.peers.peer_by_ip_mut(dest) else {
            self.on_connection_intent_ip(dest, now);
            return None;
        };

        let packet = peer.transform(packet)?;

        Some((peer.conn_id, packet))
    }

    /// Attempt to handle the given packet as a DNS packet.
    ///
    /// Returns `Ok` if the packet is in fact a DNS query with an optional response to send back.
    /// Returns `Err` if the packet is not a DNS query.
    fn handle_dns<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
        now: Instant,
    ) -> Result<Option<IpPacket<'a>>, (MutableIpPacket<'a>, IpAddr)> {
        match dns::parse(
            &self.dns_resources,
            &self.dns_resources_internal_ips,
            &self.dns_mapping,
            packet.as_immutable(),
        ) {
            Some(dns::ResolveStrategy::LocalResponse(query)) => Ok(Some(query)),
            Some(dns::ResolveStrategy::ForwardQuery(query)) => {
                // There's an edge case here, where the resolver's ip has been resolved before as
                // a dns resource... we will ignore that weird case for now.
                // Assuming a single upstream dns until #3123 lands
                if let Some(upstream_dns) = self.dns_mapping.get_by_left(&query.query.destination())
                {
                    if self
                        .cidr_resources
                        .longest_match(upstream_dns.ip())
                        .is_some()
                    {
                        return Err((packet, upstream_dns.ip()));
                    }
                }

                self.add_pending_dns_query(query);

                Ok(None)
            }
            Some(dns::ResolveStrategy::DeferredResponse(resource)) => {
                self.on_connection_intent_dns(&resource.0, now);
                self.deferred_dns_queries
                    .insert(resource, packet.as_immutable().to_owned());

                Ok(None)
            }
            None => {
                let dest = packet.destination();
                Err((packet, dest))
            }
        }
    }

    pub(crate) fn get_awaiting_connection(
        &self,
        resource: &ResourceId,
    ) -> Result<&AwaitingConnectionDetails, ConnlibError> {
        self.awaiting_connection
            .get(resource)
            .ok_or(Error::UnexpectedConnectionDetails)
    }

    pub(crate) fn attempt_to_reuse_connection(
        &mut self,
        resource: ResourceId,
        gateway: GatewayId,
    ) -> Result<Option<ReuseConnection>, ConnlibError> {
        let desc = self
            .resource_ids
            .get(&resource)
            .ok_or(Error::UnknownResource)?;

        let domain = self.get_awaiting_connection(&resource)?.domain.clone();

        if self.is_connected_to(resource, &domain) {
            return Err(Error::UnexpectedConnectionDetails);
        }

        self.awaiting_connection
            .get_mut(&resource)
            .ok_or(Error::UnexpectedConnectionDetails)?;

        self.resources_gateways.insert(resource, gateway);

        if self.peers.get(&gateway).is_none() {
            return Ok(None);
        };

        self.peers
            .add_ips_with_resource(&gateway, &self.get_resource_ip(desc, &domain), &resource);

        self.awaiting_connection.remove(&resource);

        Ok(Some(ReuseConnection {
            resource_id: resource,
            gateway_id: gateway,
            payload: domain.clone(),
        }))
    }

    pub fn on_connection_failed(&mut self, resource: ResourceId) {
        self.awaiting_connection.remove(&resource);
        self.resources_gateways.remove(&resource);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(resource_address = %resource.address, resource_id = %resource.id))]
    fn on_connection_intent_dns(&mut self, resource: &DnsResource, now: Instant) {
        self.on_connection_intent_to_resource(resource.id, Some(resource.address.clone()), now)
    }

    #[tracing::instrument(level = "debug", skip_all, fields(resource_ip = %destination, resource_id))]
    fn on_connection_intent_ip(&mut self, destination: IpAddr, now: Instant) {
        if is_definitely_not_a_resource(destination) {
            return;
        }

        let Some(resource_id) = self.get_cidr_resource_by_destination(destination) else {
            if let Some(resource) = self
                .dns_resources_internal_ips
                .iter()
                .find_map(|(r, i)| i.contains(&destination).then_some(r))
                .cloned()
            {
                self.on_connection_intent_dns(&resource, now);
            }

            tracing::trace!("Unknown resource");

            return;
        };

        tracing::Span::current().record("resource_id", tracing::field::display(&resource_id));

        self.on_connection_intent_to_resource(resource_id, None, now)
    }

    fn on_connection_intent_to_resource(
        &mut self,
        resource: ResourceId,
        domain: Option<Dname>,
        now: Instant,
    ) {
        debug_assert!(self.resource_ids.contains_key(&resource));

        let gateways = self
            .resources_gateways
            .values()
            .copied()
            .collect::<HashSet<_>>();

        match self.awaiting_connection.entry(resource) {
            Entry::Occupied(mut occupied) => {
                let time_since_last_intent = now.duration_since(occupied.get().last_intent_sent_at);

                if time_since_last_intent < Duration::from_secs(2) {
                    tracing::trace!(?time_since_last_intent, "Skipping connection intent");

                    return;
                }

                occupied.get_mut().last_intent_sent_at = now;
            }
            Entry::Vacant(vacant) => {
                vacant.insert(AwaitingConnectionDetails {
                    domain,
                    gateways: gateways.clone(),
                    last_intent_sent_at: now,
                });
            }
        }

        tracing::debug!("Sending connection intent");

        self.buffered_events.push_back(Event::ConnectionIntent {
            resource,
            connected_gateway_ids: gateways,
        });
    }

    pub fn create_peer_config_for_new_connection(
        &mut self,
        resource: ResourceId,
        domain: &Option<Dname>,
    ) -> Result<Vec<IpNetwork>, ConnlibError> {
        let desc = self
            .resource_ids
            .get(&resource)
            .ok_or(Error::ControlProtocolError)?;

        let ips = self.get_resource_ip(desc, domain);

        // Tidy up state once everything succeeded.
        self.awaiting_connection.remove(&resource);

        Ok(ips)
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.resources_gateways.get(resource).copied()
    }

    fn set_dns_mapping(&mut self, mapping: BiMap<IpAddr, DnsServer>) {
        self.dns_mapping = mapping.clone();
        self.dns_resolvers = create_resolvers(mapping);
    }

    pub fn dns_mapping(&self) -> BiMap<IpAddr, DnsServer> {
        self.dns_mapping.clone()
    }

    fn is_connected_to(&self, resource: ResourceId, domain: &Option<Dname>) -> bool {
        let Some(resource) = self.resource_ids.get(&resource) else {
            return false;
        };

        let ips = self.get_resource_ip(resource, domain);
        ips.iter().any(|ip| self.peers.exact_match(*ip).is_some())
    }

    fn get_resource_ip(
        &self,
        resource: &ResourceDescription,
        domain: &Option<Dname>,
    ) -> Vec<IpNetwork> {
        match resource {
            ResourceDescription::Dns(dns_resource) => {
                let Some(domain) = domain else {
                    return vec![];
                };

                let description = DnsResource::from_description(dns_resource, domain.clone());
                self.dns_resources_internal_ips
                    .get(&description)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .map(Into::into)
                    .collect()
            }
            ResourceDescription::Cidr(cidr) => vec![cidr.address],
        }
    }

    pub fn cleanup_connected_gateway(&mut self, gateway_id: &GatewayId) {
        self.peers.remove(gateway_id);
        self.dns_resources_internal_ips.retain(|resource, _| {
            !self
                .resources_gateways
                .get(&resource.id)
                .is_some_and(|r_gateway_id| r_gateway_id == gateway_id)
        });
    }

    fn routes(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.cidr_resources
            .iter()
            .map(|(ip, _)| ip)
            .chain(iter::once(IpNetwork::from_str(IPV4_RESOURCES).unwrap()))
            .chain(iter::once(IpNetwork::from_str(IPV6_RESOURCES).unwrap()))
            .chain(self.dns_mapping.left_values().copied().map(Into::into))
    }

    fn get_cidr_resource_by_destination(&self, destination: IpAddr) -> Option<ResourceId> {
        self.cidr_resources
            .longest_match(destination)
            .map(|(_, res)| res.id)
    }

    fn add_pending_dns_query(&mut self, query: DnsQuery) {
        let upstream = query.query.destination();
        let Some(resolver) = self.dns_resolvers.get(&upstream).cloned() else {
            tracing::warn!(%upstream, "Dropping DNS query because of unknown upstream DNS server");
            return;
        };

        let query = query.into_owned();

        if self
            .forwarded_dns_queries
            .try_push(
                {
                    let name = query.name.clone();
                    let record_type = query.record_type;

                    async move { resolver.lookup(&name, record_type).await }
                },
                query,
            )
            .is_err()
        {
            tracing::warn!("Too many DNS queries, dropping existing one");
        }
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<GatewayId>> {
        loop {
            if let Some(event) = self.buffered_events.pop_front() {
                return Poll::Ready(event);
            }

            if self.refresh_dns_timer.poll_tick(cx).is_ready() {
                let mut connections = Vec::new();

                self.peers
                    .iter_mut()
                    .for_each(|p| p.transform.expire_dns_track());

                for resource in self.dns_resources_internal_ips.keys() {
                    let Some(gateway_id) = self.resources_gateways.get(&resource.id) else {
                        continue;
                    };
                    // filter inactive connections
                    if self.peers.get(gateway_id).is_none() {
                        continue;
                    }

                    connections.push(ReuseConnection {
                        resource_id: resource.id,
                        gateway_id: *gateway_id,
                        payload: Some(resource.address.clone()),
                    });
                }
                return Poll::Ready(Event::RefreshResources { connections });
            }

            match self.forwarded_dns_queries.poll_unpin(cx) {
                Poll::Ready((Ok(response), query)) => {
                    match dns::build_response_from_resolve_result(query.query, response) {
                        Ok(Some(packet)) => return Poll::Ready(Event::SendPacket(packet)),
                        Ok(None) => continue,
                        Err(e) => {
                            tracing::warn!("Failed to build DNS response from lookup result: {e}");
                            continue;
                        }
                    }
                }
                Poll::Ready((Err(resolve_timeout), query)) => {
                    tracing::warn!(name = %query.name, server = %query.query.destination(), "DNS query timed out: {resolve_timeout}");
                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}

fn create_resolvers(
    sentinel_mapping: BiMap<IpAddr, DnsServer>,
) -> HashMap<IpAddr, TokioAsyncResolver> {
    sentinel_mapping
        .into_iter()
        .map(|(sentinel, srv)| {
            let mut resolver_config = ResolverConfig::new();
            resolver_config.add_name_server(NameServerConfig::new(srv.address(), Protocol::Udp));
            (
                sentinel,
                TokioAsyncResolver::tokio(resolver_config, Default::default()),
            )
        })
        .collect()
}

impl Default for ClientState {
    fn default() -> Self {
        // With this single timer this might mean that some DNS are refreshed too often
        // however... this also mean any resource is refresh within a 5 mins interval
        // therefore, only the first time it's added that happens, after that it doesn't matter.
        let mut interval = tokio::time::interval(Duration::from_secs(300));
        interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

        Self {
            awaiting_connection: Default::default(),
            resources_gateways: Default::default(),
            forwarded_dns_queries: FuturesTupleSet::new(
                Duration::from_secs(60),
                DNS_QUERIES_QUEUE_SIZE,
            ),
            ip_provider: IpProvider::new(
                IPV4_RESOURCES.parse().unwrap(),
                IPV6_RESOURCES.parse().unwrap(),
            ),
            dns_resources_internal_ips: Default::default(),
            dns_resources: Default::default(),
            cidr_resources: IpNetworkTable::new(),
            resource_ids: Default::default(),
            peers: Default::default(),
            deferred_dns_queries: Default::default(),
            refresh_dns_timer: interval,
            dns_mapping: Default::default(),
            dns_resolvers: Default::default(),
            buffered_events: Default::default(),
            interface_config: Default::default(),
        }
    }
}

fn effective_dns_servers(
    upstream_dns: Vec<DnsServer>,
    default_resolvers: Vec<IpAddr>,
) -> Vec<DnsServer> {
    if !upstream_dns.is_empty() {
        return upstream_dns;
    }

    let mut dns_servers = default_resolvers
        .into_iter()
        .filter(|ip| !IpNetwork::from_str(DNS_SENTINELS_V4).unwrap().contains(*ip))
        .filter(|ip| !IpNetwork::from_str(DNS_SENTINELS_V6).unwrap().contains(*ip))
        .peekable();

    if dns_servers.peek().is_none() {
        tracing::error!("No system default DNS servers available! Can't initialize resolver. DNS interception will be disabled.");
        return Vec::new();
    }

    dns_servers
        .map(|ip| {
            DnsServer::IpPort(IpDnsServer {
                address: (ip, DNS_PORT).into(),
            })
        })
        .collect()
}

fn sentinel_dns_mapping(dns: &[DnsServer]) -> BiMap<IpAddr, DnsServer> {
    let mut ip_provider = IpProvider::new(
        DNS_SENTINELS_V4.parse().unwrap(),
        DNS_SENTINELS_V6.parse().unwrap(),
    );

    dns.iter()
        .cloned()
        .map(|i| {
            (
                ip_provider
                    .get_proxy_ip_for(&i.ip())
                    .expect("We only support up to 256 IPv4 DNS servers and 256 IPv6 DNS servers"),
                i,
            )
        })
        .collect()
}
/// Compares the given [`IpAddr`] against a static set of ignored IPs that are definitely not resources.
fn is_definitely_not_a_resource(ip: IpAddr) -> bool {
    /// Source: https://en.wikipedia.org/wiki/Multicast_address#Notable_IPv4_multicast_addresses
    const IPV4_IGMP_MULTICAST: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 22);

    /// Source: <https://en.wikipedia.org/wiki/Multicast_address#Notable_IPv6_multicast_addresses>
    const IPV6_MULTICAST_ALL_ROUTERS: Ipv6Addr = Ipv6Addr::new(0xFF02, 0, 0, 0, 0, 0, 0, 0x0002);

    match ip {
        IpAddr::V4(ip4) => {
            if ip4 == IPV4_IGMP_MULTICAST {
                return true;
            }
        }
        IpAddr::V6(ip6) => {
            if ip6 == IPV6_MULTICAST_ALL_ROUTERS {
                return true;
            }
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ignores_ip4_igmp_multicast() {
        assert!(is_definitely_not_a_resource("224.0.0.22".parse().unwrap()))
    }

    #[test]
    fn ignores_ip6_multicast_all_routers() {
        assert!(is_definitely_not_a_resource("ff02::2".parse().unwrap()))
    }
}
