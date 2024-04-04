use crate::ip_packet::{IpPacket, MutableIpPacket};
use crate::peer::{PacketTransformClient, Peer};
use crate::peer_store::PeerStore;
use crate::{dns, dns::DnsQuery};
use bimap::BiMap;
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::{
    Answer, ClientPayload, DnsServer, DomainResponse, GatewayId, Interface as InterfaceConfig,
    IpDnsServer, Key, Offer, Relay, RequestConnection, ResourceDescription,
    ResourceDescriptionCidr, ResourceDescriptionDns, ResourceId, ReuseConnection,
};
use connlib_shared::{Callbacks, Dname, PublicKey, StaticSecret};
use domain::base::Rtype;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use itertools::Itertools;

use crate::utils::{earliest, stun, turn};
use crate::{ClientEvent, ClientTunnel};
use secrecy::{ExposeSecret as _, Secret};
use snownet::ClientNode;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet, VecDeque};
use std::iter;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::str::FromStr;
use std::time::{Duration, Instant};

// Using str here because Ipv4/6Network doesn't support `const` 🙃
const IPV4_RESOURCES: &str = "100.96.0.0/11";
const IPV6_RESOURCES: &str = "fd00:2021:1111:8000::/107";

const DNS_PORT: u16 = 53;
const DNS_SENTINELS_V4: &str = "100.100.111.0/24";
const DNS_SENTINELS_V6: &str = "fd00:2021:1111:8000:100:100:111:0/120";

// With this single timer this might mean that some DNS are refreshed too often
// however... this also mean any resource is refresh within a 5 mins interval
// therefore, only the first time it's added that happens, after that it doesn't matter.
const DNS_REFRESH_INTERVAL: Duration = Duration::from_secs(300);

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

impl<CB> ClientTunnel<CB>
where
    CB: Callbacks + 'static,
{
    pub fn set_resources(
        &mut self,
        resources: Vec<ResourceDescription>,
    ) -> connlib_shared::Result<()> {
        self.role_state.set_resources(resources);

        self.update_routes()?;
        self.update_resource_list();

        Ok(())
    }

    /// Adds a the given resource to the tunnel.
    pub fn add_resources(
        &mut self,
        resources: &[ResourceDescription],
    ) -> connlib_shared::Result<()> {
        self.role_state.add_resources(resources);

        self.update_routes()?;
        self.update_resource_list();

        Ok(())
    }

    pub fn remove_resources(&mut self, ids: &[ResourceId]) {
        self.role_state.remove_resources(ids);

        if let Err(err) = self.update_routes() {
            tracing::error!(?ids, "Failed to update routes: {err:?}");
        }

        self.update_resource_list();
    }

    fn update_resource_list(&self) {
        self.callbacks
            .on_update_resources(self.role_state.resources());
    }

    /// Updates the system's dns
    pub fn set_dns(&mut self, new_dns: Vec<IpAddr>) -> connlib_shared::Result<()> {
        // We store the sentinel dns both in the config and in the system's resolvers
        // but when we calculate the dns mapping, those are ignored.
        let dns_changed = self.role_state.update_system_resolvers(new_dns);

        if !dns_changed {
            return Ok(());
        }

        self.io
            .set_upstream_dns_servers(self.role_state.dns_mapping());

        if let Some(config) = self.role_state.interface_config.as_ref().cloned() {
            self.update_interface(config)?;
        };

        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&mut self, config: InterfaceConfig) -> connlib_shared::Result<()> {
        self.role_state.interface_config = Some(config.clone());
        let dns_changed = self.role_state.update_dns_mapping();

        if dns_changed {
            self.io
                .set_upstream_dns_servers(self.role_state.dns_mapping());
        }

        self.update_interface(config)?;

        Ok(())
    }

    pub(crate) fn update_interface(
        &mut self,
        config: InterfaceConfig,
    ) -> connlib_shared::Result<()> {
        let callbacks = self.callbacks.clone();

        self.io.device_mut().set_config(
            &config,
            // We can just sort in here because sentinel ips are created in order
            self.role_state
                .dns_mapping
                .left_values()
                .copied()
                .sorted()
                .collect(),
            &callbacks,
        )?;

        self.io
            .device_mut()
            .set_routes(self.role_state.routes().collect(), &self.callbacks)?;
        let name = self.io.device_mut().name().to_owned();

        tracing::debug!(ip4 = %config.ipv4, ip6 = %config.ipv6, %name, "TUN device initialized");

        Ok(())
    }

    pub fn cleanup_connection(&mut self, id: ResourceId) {
        self.role_state.on_connection_failed(id);
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn update_routes(&mut self) -> connlib_shared::Result<()> {
        self.io
            .device_mut()
            .set_routes(self.role_state.routes().collect(), &self.callbacks)?;

        Ok(())
    }

    pub fn add_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String) {
        self.role_state
            .node
            .add_remote_candidate(conn_id, ice_candidate, Instant::now());
    }

    pub fn create_or_reuse_connection(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        relays: Vec<Relay>,
    ) -> connlib_shared::Result<Request> {
        self.role_state.create_or_reuse_connection(
            resource_id,
            gateway_id,
            stun(&relays, |addr| self.io.sockets_ref().can_handle(addr)),
            turn(&relays, |addr| self.io.sockets_ref().can_handle(addr)),
        )
    }

    pub fn received_offer_response(
        &mut self,
        resource_id: ResourceId,
        answer: Answer,
        domain_response: Option<DomainResponse>,
        gateway_public_key: PublicKey,
    ) -> connlib_shared::Result<()> {
        self.role_state
            .accept_answer(answer, resource_id, gateway_public_key, domain_response)?;

        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self, resource_id))]
    pub fn received_domain_parameters(
        &mut self,
        resource_id: ResourceId,
        domain_response: DomainResponse,
    ) -> connlib_shared::Result<()> {
        self.role_state
            .received_domain_parameters(resource_id, domain_response)?;

        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

fn send_dns_answer(
    role_state: &mut ClientState,
    qtype: Rtype,
    resource_description: &DnsResource,
    addrs: &HashSet<IpAddr>,
) {
    let packet = role_state
        .deferred_dns_queries
        .remove(&(resource_description.clone(), qtype));
    if let Some(packet) = packet {
        let Some(packet) = dns::create_local_answer(addrs, packet) else {
            return;
        };
        role_state.buffered_packets.push_back(packet);
    }
}

pub struct ClientState {
    awaiting_connection: HashMap<ResourceId, AwaitingConnectionDetails>,
    resources_gateways: HashMap<ResourceId, GatewayId>,

    pub dns_resources_internal_ips: HashMap<DnsResource, HashSet<IpAddr>>,
    dns_resources: HashMap<String, ResourceDescriptionDns>,
    cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    pub resource_ids: HashMap<ResourceId, ResourceDescription>,
    pub deferred_dns_queries: HashMap<(DnsResource, Rtype), IpPacket<'static>>,

    pub peers: PeerStore<GatewayId, PacketTransformClient, HashSet<ResourceId>>,

    node: ClientNode<GatewayId>,

    pub ip_provider: IpProvider,

    dns_mapping: BiMap<IpAddr, DnsServer>,

    buffered_events: VecDeque<ClientEvent>,
    interface_config: Option<InterfaceConfig>,
    buffered_packets: VecDeque<IpPacket<'static>>,

    /// DNS queries that we need to forward to the system resolver.
    buffered_dns_queries: VecDeque<DnsQuery<'static>>,

    next_dns_refresh: Option<Instant>,

    system_resolvers: Vec<IpAddr>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AwaitingConnectionDetails {
    pub domain: Option<Dname>,
    gateways: HashSet<GatewayId>,
    pub last_intent_sent_at: Instant,
}

impl ClientState {
    pub(crate) fn new(private_key: StaticSecret) -> Self {
        Self {
            awaiting_connection: Default::default(),
            resources_gateways: Default::default(),
            ip_provider: IpProvider::for_resources(),
            dns_resources_internal_ips: Default::default(),
            dns_resources: Default::default(),
            cidr_resources: IpNetworkTable::new(),
            resource_ids: Default::default(),
            peers: Default::default(),
            deferred_dns_queries: Default::default(),
            dns_mapping: Default::default(),
            buffered_events: Default::default(),
            interface_config: Default::default(),
            buffered_packets: Default::default(),
            buffered_dns_queries: Default::default(),
            next_dns_refresh: Default::default(),
            node: ClientNode::new(private_key),
            system_resolvers: Default::default(),
        }
    }

    fn resources(&self) -> Vec<ResourceDescription> {
        self.resource_ids.values().sorted().cloned().collect_vec()
    }

    pub(crate) fn encapsulate<'s>(
        &'s mut self,
        packet: MutableIpPacket<'_>,
        now: Instant,
    ) -> Option<snownet::Transmit<'s>> {
        let (packet, dest) = match self.handle_dns(packet, now) {
            Ok(response) => {
                self.buffered_packets.push_back(response?.to_owned());
                return None;
            }
            Err(non_dns_packet) => non_dns_packet,
        };

        let Some(peer) = self.peers.peer_by_ip_mut(dest) else {
            self.on_connection_intent_ip(dest, now);
            return None;
        };

        let packet = peer.transform(packet)?;

        let transmit = self
            .node
            .encapsulate(peer.conn_id, packet.as_immutable().into(), Instant::now())
            .inspect_err(|e| tracing::debug!("Failed to encapsulate: {e}"))
            .ok()??;

        Some(transmit)
    }

    pub(crate) fn decapsulate<'b>(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
        buffer: &'b mut [u8],
    ) -> Option<IpPacket<'b>> {
        let (conn_id, packet) = self.node.decapsulate(
            local,
            from,
            packet.as_ref(),
            now,
            buffer,
        )
        .inspect_err(|e| tracing::warn!(%local, %from, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {e}"))
        .ok()??;

        let Some(peer) = self.peers.get_mut(&conn_id) else {
            tracing::error!(%conn_id, %local, %from, "Couldn't find connection");

            return None;
        };

        let packet = match peer.untransform(packet.into()) {
            Ok(packet) => packet,
            Err(e) => {
                tracing::warn!(%conn_id, %local, %from, "Failed to transform packet: {e}");

                return None;
            }
        };

        Some(packet.into_immutable())
    }

    #[tracing::instrument(level = "trace", skip_all, fields(%resource_id))]
    fn accept_answer(
        &mut self,
        answer: Answer,
        resource_id: ResourceId,
        gateway: PublicKey,
        domain_response: Option<DomainResponse>,
    ) -> connlib_shared::Result<()> {
        let gateway_id = self
            .gateway_by_resource(&resource_id)
            .ok_or(Error::UnknownResource)?;

        self.node.accept_answer(
            gateway_id,
            gateway,
            snownet::Answer {
                credentials: snownet::Credentials {
                    username: answer.username,
                    password: answer.password,
                },
            },
            Instant::now(),
        );

        let desc = self
            .resource_ids
            .get(&resource_id)
            .ok_or(Error::ControlProtocolError)?;

        let ips = self.get_resource_ip(desc, &domain_response.as_ref().map(|d| d.domain.clone()));

        // Tidy up state once everything succeeded.
        self.awaiting_connection.remove(&resource_id);

        let resource_ids = HashSet::from([resource_id]);
        let mut peer: Peer<_, PacketTransformClient, _> =
            Peer::new(gateway_id, Default::default(), &ips, resource_ids);
        peer.transform.set_dns(self.dns_mapping());
        self.peers.insert(peer, &[]);

        let peer_ips = if let Some(domain_response) = domain_response {
            self.dns_response(&resource_id, &domain_response, &gateway_id)?
        } else {
            ips
        };

        self.peers
            .add_ips_with_resource(&gateway_id, &peer_ips, &resource_id);

        Ok(())
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%resource_id, %gateway_id))]
    fn create_or_reuse_connection(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        allowed_stun_servers: HashSet<SocketAddr>,
        allowed_turn_servers: HashSet<(SocketAddr, String, String, String)>,
    ) -> connlib_shared::Result<Request> {
        tracing::trace!("create_or_reuse_connection");

        let desc = self
            .resource_ids
            .get(&resource_id)
            .ok_or(Error::UnknownResource)?;

        let domain = self.get_awaiting_connection(&resource_id)?.domain.clone();

        if self.is_connected_to(resource_id, &domain) {
            return Err(Error::UnexpectedConnectionDetails);
        }

        let awaiting_connection = self
            .awaiting_connection
            .get(&resource_id)
            .ok_or(Error::UnexpectedConnectionDetails)?
            .clone();

        self.resources_gateways.insert(resource_id, gateway_id);

        if self.peers.get(&gateway_id).is_some() {
            self.peers.add_ips_with_resource(
                &gateway_id,
                &self.get_resource_ip(desc, &domain),
                &resource_id,
            );

            self.awaiting_connection.remove(&resource_id);

            return Ok(Request::ReuseConnection(ReuseConnection {
                resource_id,
                gateway_id,
                payload: domain.clone(),
            }));
        };

        if self.node.is_expecting_answer(gateway_id) {
            return Err(Error::PendingConnection);
        }

        let offer = self.node.new_connection(
            gateway_id,
            allowed_stun_servers,
            allowed_turn_servers,
            awaiting_connection.last_intent_sent_at,
            Instant::now(),
        );

        return Ok(Request::NewConnection(RequestConnection {
            resource_id,
            gateway_id,
            client_preshared_key: Secret::new(Key(*offer.session_key.expose_secret())),
            client_payload: ClientPayload {
                ice_parameters: Offer {
                    username: offer.credentials.username,
                    password: offer.credentials.password,
                },
                domain: awaiting_connection.domain,
            },
        }));
    }

    fn received_domain_parameters(
        &mut self,
        resource_id: ResourceId,
        domain_response: DomainResponse,
    ) -> connlib_shared::Result<()> {
        let gateway_id = self
            .gateway_by_resource(&resource_id)
            .ok_or(Error::UnknownResource)?;

        let peer_ips = self.dns_response(&resource_id, &domain_response, &gateway_id)?;

        self.peers
            .add_ips_with_resource(&gateway_id, &peer_ips, &resource_id);

        Ok(())
    }

    fn dns_response(
        &mut self,
        resource_id: &ResourceId,
        domain_response: &DomainResponse,
        peer_id: &GatewayId,
    ) -> connlib_shared::Result<Vec<IpNetwork>> {
        let peer = self
            .peers
            .get_mut(peer_id)
            .ok_or(Error::ControlProtocolError)?;

        let resource_description = self
            .resource_ids
            .get(resource_id)
            .ok_or(Error::UnknownResource)?
            .clone();

        let ResourceDescription::Dns(resource_description) = resource_description else {
            // We should never get a domain_response for a CIDR resource!
            return Err(Error::ControlProtocolError);
        };

        let resource_description =
            DnsResource::from_description(&resource_description, domain_response.domain.clone());

        let addrs: HashSet<_> = domain_response
            .address
            .iter()
            .filter_map(|external_ip| {
                peer.transform
                    .get_or_assign_translation(external_ip, &mut self.ip_provider)
            })
            .collect();

        self.dns_resources_internal_ips
            .insert(resource_description.clone(), addrs.clone());

        send_dns_answer(self, Rtype::Aaaa, &resource_description, &addrs);
        send_dns_answer(self, Rtype::A, &resource_description, &addrs);

        Ok(addrs.iter().copied().map(Into::into).collect())
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

                self.buffered_dns_queries.push_back(query.into_owned());

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

        self.buffered_events
            .push_back(ClientEvent::ConnectionIntent {
                resource,
                connected_gateway_ids: gateways,
            });
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.resources_gateways.get(resource).copied()
    }

    fn set_dns_mapping(&mut self, new_mapping: BiMap<IpAddr, DnsServer>) {
        self.dns_mapping = new_mapping.clone();
        self.peers
            .iter_mut()
            .for_each(|p| p.transform.set_dns(new_mapping.clone()));
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

    #[must_use]
    fn update_system_resolvers(&mut self, new_dns: Vec<IpAddr>) -> bool {
        self.system_resolvers = new_dns;

        self.update_dns_mapping()
    }

    pub fn poll_packets(&mut self) -> Option<IpPacket<'static>> {
        self.buffered_packets.pop_front()
    }

    pub fn poll_dns_queries(&mut self) -> Option<DnsQuery<'static>> {
        self.buffered_dns_queries.pop_front()
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        earliest(self.next_dns_refresh, self.node.poll_timeout())
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.node.handle_timeout(now);

        match self.next_dns_refresh {
            Some(next_dns_refresh) if now >= next_dns_refresh => {
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

                self.buffered_events
                    .push_back(ClientEvent::RefreshResources { connections });

                self.next_dns_refresh = Some(now + DNS_REFRESH_INTERVAL);
            }
            None => self.next_dns_refresh = Some(now + DNS_REFRESH_INTERVAL),
            Some(_) => {}
        }

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) => {
                    self.cleanup_connected_gateway(&id);
                }
                snownet::Event::SignalIceCandidate {
                    connection,
                    candidate,
                } => self
                    .buffered_events
                    .push_back(ClientEvent::SignalIceCandidate {
                        conn_id: connection,
                        candidate,
                    }),
                _ => {}
            }
        }
    }

    pub(crate) fn poll_event(&mut self) -> Option<ClientEvent> {
        self.buffered_events.pop_front()
    }

    pub(crate) fn reconnect(&mut self, now: Instant) {
        tracing::info!("Network change detected, refreshing connections");
        self.node.reconnect(now)
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit<'_>> {
        self.node.poll_transmit()
    }

    fn set_resources(&mut self, new_resources: Vec<ResourceDescription>) {
        self.remove_resources(
            &HashSet::from_iter(self.resource_ids.keys().copied())
                .difference(&HashSet::<ResourceId>::from_iter(
                    new_resources.iter().map(|r| r.id()),
                ))
                .copied()
                .collect_vec(),
        );

        self.add_resources(
            &HashSet::from_iter(new_resources.iter().cloned())
                .difference(&HashSet::<ResourceDescription>::from_iter(
                    self.resource_ids.values().cloned(),
                ))
                .cloned()
                .collect_vec(),
        );
    }

    fn add_resources(&mut self, resources: &[ResourceDescription]) {
        for resource_description in resources {
            if let Some(resource) = self.resource_ids.get(&resource_description.id()) {
                if resource.has_different_address(resource_description) {
                    self.remove_resources(&[resource.id()]);
                }
            }

            match &resource_description {
                ResourceDescription::Dns(dns) => {
                    self.dns_resources.insert(dns.address.clone(), dns.clone());
                }
                ResourceDescription::Cidr(cidr) => {
                    self.cidr_resources.insert(cidr.address, cidr.clone());
                }
            }

            self.resource_ids
                .insert(resource_description.id(), resource_description.clone());
        }
    }

    #[tracing::instrument(level = "debug", skip_all, fields(?ids))]
    fn remove_resources(&mut self, ids: &[ResourceId]) {
        for id in ids {
            self.awaiting_connection.remove(id);
            self.dns_resources_internal_ips.retain(|r, _| r.id != *id);
            self.dns_resources.retain(|_, r| r.id != *id);
            self.cidr_resources.retain(|_, r| r.id != *id);
            self.deferred_dns_queries.retain(|(r, _), _| r.id != *id);

            self.resource_ids.remove(id);

            let Some(gateway_id) = self.resources_gateways.remove(id) else {
                tracing::debug!("No gateway associated with resource");
                continue;
            };

            let Some(peer) = self.peers.get_mut(&gateway_id) else {
                continue;
            };

            // First we remove the id from all allowed ips
            for (network, resources) in peer
                .allowed_ips
                .iter_mut()
                .filter(|(_, resources)| resources.contains(id))
            {
                resources.remove(id);

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
                self.peers.remove(&gateway_id);
                // TODO: should we have a Node::remove_connection?
            }
        }

        tracing::debug!("Resources removed")
    }

    fn update_dns_mapping(&mut self) -> bool {
        let Some(config) = &self.interface_config else {
            return false;
        };

        let effective_dns_servers =
            effective_dns_servers(config.upstream_dns.clone(), self.system_resolvers.clone());

        if HashSet::<&DnsServer>::from_iter(effective_dns_servers.iter())
            == HashSet::from_iter(self.dns_mapping.right_values())
        {
            return false;
        }

        let dns_mapping = sentinel_dns_mapping(
            &effective_dns_servers,
            self.dns_mapping()
                .left_values()
                .copied()
                .map(Into::into)
                .collect_vec(),
        );

        self.set_dns_mapping(dns_mapping.clone());

        true
    }
}

fn effective_dns_servers(
    upstream_dns: Vec<DnsServer>,
    default_resolvers: Vec<IpAddr>,
) -> Vec<DnsServer> {
    let mut upstream_dns = upstream_dns.into_iter().filter_map(not_sentinel).peekable();
    if upstream_dns.peek().is_some() {
        return upstream_dns.collect();
    }

    let mut dns_servers = default_resolvers
        .into_iter()
        .map(|ip| {
            DnsServer::IpPort(IpDnsServer {
                address: (ip, DNS_PORT).into(),
            })
        })
        .filter_map(not_sentinel)
        .peekable();

    if dns_servers.peek().is_none() {
        tracing::error!("No system default DNS servers available! Can't initialize resolver. DNS interception will be disabled.");
        return Vec::new();
    }

    dns_servers.collect()
}

fn not_sentinel(srv: DnsServer) -> Option<DnsServer> {
    (!IpNetwork::from_str(DNS_SENTINELS_V4)
        .unwrap()
        .contains(srv.ip())
        && !IpNetwork::from_str(DNS_SENTINELS_V6)
            .unwrap()
            .contains(srv.ip()))
    .then_some(srv)
}

fn sentinel_dns_mapping(
    dns: &[DnsServer],
    old_sentinels: Vec<IpNetwork>,
) -> BiMap<IpAddr, DnsServer> {
    let mut ip_provider = IpProvider::for_stub_dns_servers(old_sentinels);

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

pub struct IpProvider {
    ipv4: Box<dyn Iterator<Item = Ipv4Addr> + Send + Sync>,
    ipv6: Box<dyn Iterator<Item = Ipv6Addr> + Send + Sync>,
}

impl IpProvider {
    pub fn for_resources() -> Self {
        IpProvider::new(
            IPV4_RESOURCES.parse().unwrap(),
            IPV6_RESOURCES.parse().unwrap(),
            vec![
                DNS_SENTINELS_V4.parse().unwrap(),
                DNS_SENTINELS_V6.parse().unwrap(),
            ],
        )
    }

    pub fn for_stub_dns_servers(exclusions: Vec<IpNetwork>) -> Self {
        IpProvider::new(
            DNS_SENTINELS_V4.parse().unwrap(),
            DNS_SENTINELS_V6.parse().unwrap(),
            exclusions,
        )
    }

    fn new(ipv4: Ipv4Network, ipv6: Ipv6Network, exclusions: Vec<IpNetwork>) -> Self {
        Self {
            ipv4: Box::new({
                let exclusions = exclusions.clone();
                ipv4.hosts()
                    .filter(move |ip| !exclusions.iter().any(|e| e.contains(*ip)))
            }),
            ipv6: Box::new({
                let exclusions = exclusions.clone();
                ipv6.subnets_with_prefix(128)
                    .map(|ip| ip.network_address())
                    .filter(move |ip| !exclusions.iter().any(|e| e.contains(*ip)))
            }),
        }
    }

    pub fn get_proxy_ip_for(&mut self, ip: &IpAddr) -> Option<IpAddr> {
        let proxy_ip = match ip {
            IpAddr::V4(_) => self.ipv4.next().map(Into::into),
            IpAddr::V6(_) => self.ipv6.next().map(Into::into),
        };

        if proxy_ip.is_none() {
            // TODO: we might want to make the iterator cyclic or another strategy to prevent ip exhaustion
            // this might happen in ipv4 if tokens are too long lived.
            tracing::error!("IP exhaustion: Please reset your client");
        }

        proxy_ip
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand_core::OsRng;

    #[test]
    fn ignores_ip4_igmp_multicast() {
        assert!(is_definitely_not_a_resource(ip("224.0.0.22")))
    }

    #[test]
    fn ignores_ip6_multicast_all_routers() {
        assert!(is_definitely_not_a_resource(ip("ff02::2")))
    }

    #[test]
    fn update_system_dns_works() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_without_dns());

        let dns_changed = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);

        assert!(dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.1.1.1:53")]);
    }

    #[test]
    fn update_system_dns_without_change_is_a_no_op() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_without_dns());

        let _ = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);
        let dns_changed = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);

        assert!(!dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.1.1.1:53")]);
    }

    #[test]
    fn update_system_dns_with_change_works() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_without_dns());

        let _ = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);
        let dns_changed = client_state.update_system_resolvers(vec![ip("1.0.0.1")]);

        assert!(dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.0.0.1:53")]);
    }

    #[test]
    fn update_to_system_with_sentinels_are_ignored() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_without_dns());

        let _ = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);
        let dns_changed = client_state.update_system_resolvers(vec![
            ip("1.1.1.1"),
            ip("100.100.111.1"),
            ip("fd00:2021:1111:8000:100:100:111:0"),
        ]);

        assert!(!dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.1.1.1:53")]);
    }

    #[test]
    fn upstream_dns_wins_over_system() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_with_dns());

        let dns_changed = client_state.update_dns_mapping();
        assert!(dns_changed);

        let dns_changed = client_state.update_system_resolvers(vec![ip("1.0.0.1")]);
        assert!(!dns_changed);

        dns_mapping_is_exactly(client_state.dns_mapping(), dns_list());
    }

    #[test]
    fn upstream_dns_change_updates() {
        let mut client_state = ClientState::for_test();

        client_state.interface_config = Some(interface_config_with_dns());

        let dns_changed = client_state.update_dns_mapping();
        assert!(dns_changed);

        let mut new_config = interface_config_without_dns();
        new_config.upstream_dns = vec![dns("8.8.8.8:53")];
        client_state.interface_config = Some(new_config);

        let dns_changed = client_state.update_dns_mapping();
        assert!(dns_changed);

        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("8.8.8.8:53")]);
    }

    #[test]
    fn upstream_dns_no_change_is_a_no_op() {
        let mut client_state = ClientState::for_test();

        client_state.interface_config = Some(interface_config_with_dns());
        let dns_changed = client_state.update_system_resolvers(vec![ip("1.0.0.1")]);

        assert!(dns_changed);

        client_state.interface_config = Some(interface_config_with_dns());
        let dns_changed = client_state.update_dns_mapping();

        assert!(!dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), dns_list());
    }

    #[test]
    fn upstream_dns_sentinels_are_ignored() {
        let mut client_state = ClientState::for_test();

        let mut config = interface_config_with_dns();
        client_state.interface_config = Some(config.clone());

        client_state.update_dns_mapping();

        config.upstream_dns.push(dns("100.100.111.1:53"));
        config
            .upstream_dns
            .push(dns("[fd00:2021:1111:8000:100:100:111:0]:53"));
        client_state.interface_config = Some(config);
        let dns_changed = client_state.update_dns_mapping();

        assert!(!dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), dns_list())
    }

    #[test]
    fn system_dns_takes_over_when_upstream_are_unset() {
        let mut client_state = ClientState::for_test();

        client_state.interface_config = Some(interface_config_with_dns());
        client_state.update_dns_mapping();

        let _ = client_state.update_system_resolvers(vec![ip("1.0.0.1")]);
        client_state.interface_config = Some(interface_config_without_dns());
        let dns_changed = client_state.update_dns_mapping();

        assert!(dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.0.0.1:53")]);
    }

    #[test]
    fn sentinel_dns_works() {
        let servers = dns_list();
        let sentinel_dns = sentinel_dns_mapping(&servers, vec![]);

        for server in servers {
            assert!(sentinel_dns
                .get_by_right(&server)
                .is_some_and(|s| sentinel_ranges().iter().any(|e| e.contains(*s))))
        }
    }

    #[test]
    fn sentinel_dns_excludes_old_ones() {
        let servers = dns_list();
        let sentinel_dns_old = sentinel_dns_mapping(&servers, vec![]);
        let sentinel_dns_new = sentinel_dns_mapping(
            &servers,
            sentinel_dns_old
                .left_values()
                .copied()
                .map(Into::into)
                .collect_vec(),
        );

        assert!(
            HashSet::<&IpAddr>::from_iter(sentinel_dns_old.left_values())
                .is_disjoint(&HashSet::from_iter(sentinel_dns_new.left_values()))
        )
    }

    // FIXME: This test does not make any sense.
    // I would expect `set_resources` to replace everything that is there.
    // Naturally, that will result in "updates" to resources that changed in-between.
    //
    // #[test]
    // fn set_resource_updates_old_resource_with_same_id() {
    //     let mut client_state = ClientState::for_test();

    //     client_state.set_resources(vec![
    //         cidr_foo_resource("10.0.0.0/24"),
    //         dns_bar_resource("baz.com"),
    //     ]);
    //     client_state.set_resources(vec![cidr_foo_resource("11.0.0.0/24")]);

    //     assert_eq!(
    //         hashset(client_state.resources().iter()),
    //         hashset([cidr_foo_resource("11.0.0.0/24")].iter())
    //     );
    //     assert_eq!(
    //         hashset(client_state.routes()),
    //         expected_routes(vec![IpNetwork::from_str("11.0.0.0/24").unwrap()])
    //     );
    // }

    // This test also does not make any sense.
    // Replacing a set with an identical set can never be observed.
    // #[test]
    // fn set_resource_keeps_resource_if_unchanged() {
    //     let mut client_state = ClientState::for_test();

    //     client_state.set_resources(vec![
    //         cidr_foo_resource("10.0.0.0/24"),
    //         dns_bar_resource("baz.com"),
    //     ]);
    //     client_state.set_resources(vec![cidr_foo_resource("10.0.0.0/24")]);

    //     assert_eq!(
    //         hashset(client_state.resources().iter()),
    //         hashset([cidr_foo_resource("10.0.0.0/24")].iter())
    //     );
    //     assert_eq!(
    //         hashset(client_state.routes()),
    //         expected_routes(vec![IpNetwork::from_str("10.0.0.0/24").unwrap()])
    //     );
    // }

    impl ClientState {
        pub fn for_test() -> ClientState {
            ClientState::new(StaticSecret::random_from_rng(OsRng))
        }
    }

    fn dns_mapping_is_exactly(mapping: BiMap<IpAddr, DnsServer>, servers: Vec<DnsServer>) {
        assert_eq!(
            HashSet::<&DnsServer>::from_iter(mapping.right_values()),
            HashSet::from_iter(servers.iter())
        )
    }

    fn interface_config_without_dns() -> InterfaceConfig {
        InterfaceConfig {
            ipv4: "10.0.0.1".parse().unwrap(),
            ipv6: "fe80::".parse().unwrap(),
            upstream_dns: Vec::new(),
        }
    }

    fn interface_config_with_dns() -> InterfaceConfig {
        InterfaceConfig {
            ipv4: "10.0.0.1".parse().unwrap(),
            ipv6: "fe80::".parse().unwrap(),
            upstream_dns: dns_list(),
        }
    }

    fn sentinel_ranges() -> Vec<IpNetwork> {
        vec![
            IpNetwork::from_str(DNS_SENTINELS_V4).unwrap(),
            IpNetwork::from_str(DNS_SENTINELS_V6).unwrap(),
        ]
    }

    fn dns_list() -> Vec<DnsServer> {
        vec![
            dns("1.1.1.1:53"),
            dns("1.0.0.1:53"),
            dns("[2606:4700:4700::1111]:53"),
        ]
    }

    fn dns(address: &str) -> DnsServer {
        DnsServer::IpPort(IpDnsServer {
            address: address.parse().unwrap(),
        })
    }

    fn ip(addr: &str) -> IpAddr {
        addr.parse().unwrap()
    }
}

#[cfg(test)]
mod testutils {
    use super::*;

    pub fn expected_routes(resource_routes: Vec<IpNetwork>) -> HashSet<IpNetwork> {
        HashSet::from_iter(
            resource_routes
                .into_iter()
                .chain(iter::once(IpNetwork::from_str(IPV4_RESOURCES).unwrap()))
                .chain(iter::once(IpNetwork::from_str(IPV6_RESOURCES).unwrap())),
        )
    }

    pub fn hashset<T: std::hash::Hash + Eq, B: ToOwned<Owned = T>>(
        val: impl IntoIterator<Item = B>,
    ) -> HashSet<T> {
        HashSet::from_iter(val.into_iter().map(|b| b.to_owned()))
    }
}

#[cfg(all(test, feature = "proptest"))]
mod proptests {
    use super::*;
    use connlib_shared::proptest::*;
    use testutils::*;

    #[test_strategy::proptest]
    fn cidr_resources_are_turned_into_routes(
        #[strategy(cidr_resource())] resource1: ResourceDescriptionCidr,
        #[strategy(cidr_resource())] resource2: ResourceDescriptionCidr,
    ) {
        let mut client_state = ClientState::for_test();

        client_state.add_resources(&[
            ResourceDescription::Cidr(resource1.clone()),
            ResourceDescription::Cidr(resource2.clone()),
        ]);

        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![resource1.address, resource2.address])
        );
    }

    #[test_strategy::proptest]
    fn added_resources_show_up_as_resoucres(
        #[strategy(cidr_resource())] resource1: ResourceDescriptionCidr,
        #[strategy(dns_resource())] resource2: ResourceDescriptionDns,
        #[strategy(cidr_resource())] resource3: ResourceDescriptionCidr,
    ) {
        let mut client_state = ClientState::for_test();

        client_state.add_resources(&[
            ResourceDescription::Cidr(resource1.clone()),
            ResourceDescription::Dns(resource2.clone()),
        ]);

        assert_eq!(
            hashset(client_state.resources().iter()),
            hashset(&[
                ResourceDescription::Cidr(resource1.clone()),
                ResourceDescription::Dns(resource2.clone())
            ])
        );

        client_state.add_resources(&[ResourceDescription::Cidr(resource3.clone())]);

        assert_eq!(
            hashset(client_state.resources().iter()),
            hashset(&[
                ResourceDescription::Cidr(resource1),
                ResourceDescription::Dns(resource2),
                ResourceDescription::Cidr(resource3)
            ])
        );
    }

    #[test_strategy::proptest]
    fn adding_same_resource_with_different_address_updates_the_address(
        #[strategy(cidr_resource())] resource: ResourceDescriptionCidr,
        #[strategy(ip_network())] new_address: IpNetwork,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&[ResourceDescription::Cidr(resource.clone())]);

        let updated_resource = ResourceDescriptionCidr {
            address: new_address,
            ..resource
        };

        client_state.add_resources(&[ResourceDescription::Cidr(updated_resource.clone())]);

        assert_eq!(
            hashset(client_state.resources().iter()),
            hashset(&[ResourceDescription::Cidr(updated_resource),])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![new_address])
        );
    }

    #[test_strategy::proptest]
    fn adding_cidr_resource_with_same_id_as_dns_resource_replaces_dns_resource(
        #[strategy(dns_resource())] resource: ResourceDescriptionDns,
        #[strategy(ip_network())] address: IpNetwork,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&[ResourceDescription::Dns(resource.clone())]);

        let dns_as_cidr_resource = ResourceDescriptionCidr {
            address,
            id: resource.id,
            name: resource.name,
        };

        client_state.add_resources(&[ResourceDescription::Cidr(dns_as_cidr_resource.clone())]);

        assert_eq!(
            hashset(client_state.resources().iter()),
            hashset(&[ResourceDescription::Cidr(dns_as_cidr_resource),])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![address])
        );
    }

    #[test_strategy::proptest]
    fn resources_can_be_removed(
        #[strategy(dns_resource())] dns_resource: ResourceDescriptionDns,
        #[strategy(cidr_resource())] cidr_resource: ResourceDescriptionCidr,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&[
            ResourceDescription::Dns(dns_resource.clone()),
            ResourceDescription::Cidr(cidr_resource.clone()),
        ]);

        client_state.remove_resources(&[dns_resource.id]);

        assert_eq!(
            hashset(client_state.resources().iter()),
            hashset(&[ResourceDescription::Cidr(cidr_resource.clone())])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![cidr_resource.address])
        );

        client_state.remove_resources(&[cidr_resource.id]);

        assert_eq!(hashset(client_state.resources().iter()), hashset(&[]));
        assert_eq!(hashset(client_state.routes()), expected_routes(vec![]));
    }

    #[test_strategy::proptest]
    fn resources_can_be_replaced(
        #[strategy(dns_resource())] dns_resource1: ResourceDescriptionDns,
        #[strategy(dns_resource())] dns_resource2: ResourceDescriptionDns,
        #[strategy(cidr_resource())] cidr_resource1: ResourceDescriptionCidr,
        #[strategy(cidr_resource())] cidr_resource2: ResourceDescriptionCidr,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&[
            ResourceDescription::Dns(dns_resource1),
            ResourceDescription::Cidr(cidr_resource1),
        ]);

        client_state.set_resources(vec![
            ResourceDescription::Dns(dns_resource2.clone()),
            ResourceDescription::Cidr(cidr_resource2.clone()),
        ]);

        assert_eq!(
            hashset(client_state.resources().iter()),
            hashset(&[
                ResourceDescription::Dns(dns_resource2.clone()),
                ResourceDescription::Cidr(cidr_resource2.clone()),
            ])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![cidr_resource2.address])
        );
    }
}
