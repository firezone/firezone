use crate::bounded_queue::BoundedQueue;
use crate::device_channel::{Device, Packet};
use crate::ip_packet::{IpPacket, MutableIpPacket};
use crate::peer::PacketTransformClient;
use crate::{
    dns, ConnectedPeer, DnsFallbackStrategy, DnsQuery, Event, PeerConfig, RoleState, Tunnel,
    DNS_QUERIES_QUEUE_SIZE, ICE_GATHERING_TIMEOUT_SECONDS, MAX_CONCURRENT_ICE_GATHERING,
};
use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::{
    GatewayId, Interface as InterfaceConfig, Key, ResourceDescription, ResourceDescriptionCidr,
    ResourceDescriptionDns, ResourceId, ReuseConnection, SecretKey,
};
use connlib_shared::{Callbacks, Dname, DNS_SENTINEL};
use domain::base::Rtype;
use futures::channel::mpsc::Receiver;
use futures::stream;
use futures_bounded::{PushError, StreamMap};
use hickory_resolver::lookup::Lookup;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use itertools::Itertools;

use rand_core::OsRng;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::time::Instant;
use webrtc::ice_transport::ice_candidate::RTCIceCandidate;

// Using str here because Ipv4/6Network doesn't support `const` 🙃
const IPV4_RESOURCES: &str = "100.96.0.0/11";
const IPV6_RESOURCES: &str = "fd00:2021:1111:8000::/107";

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

impl<CB> Tunnel<CB, ClientState>
where
    CB: Callbacks + 'static,
{
    /// Adds a the given resource to the tunnel.
    ///
    /// Once added, when a packet for the resource is intercepted a new data channel will be created
    /// and packets will be wrapped with wireguard and sent through it.
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn add_resource(
        &self,
        resource_description: ResourceDescription,
    ) -> connlib_shared::Result<()> {
        match &resource_description {
            ResourceDescription::Dns(dns) => {
                self.role_state
                    .lock()
                    .dns_resources
                    .insert(dns.address.clone(), dns.clone());
            }
            ResourceDescription::Cidr(cidr) => {
                self.add_route(cidr.address)?;

                self.role_state
                    .lock()
                    .cidr_resources
                    .insert(cidr.address, cidr.clone());
            }
        }

        let mut role_state = self.role_state.lock();
        role_state
            .resource_ids
            .insert(resource_description.id(), resource_description);
        self.callbacks
            .on_update_resources(role_state.resource_ids.values().cloned().collect())?;
        Ok(())
    }

    /// Writes the response to a DNS lookup
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn write_dns_lookup_response(
        &self,
        response: hickory_resolver::error::ResolveResult<Lookup>,
        query: IpPacket<'static>,
    ) -> connlib_shared::Result<()> {
        if let Some(pkt) = dns::build_response_from_resolve_result(query, response)? {
            let Some(ref device) = *self.device.load() else {
                return Ok(());
            };

            device.write(pkt)?;
        }

        Ok(())
    }

    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        if !config.upstream_dns.is_empty() {
            self.role_state.lock().dns_strategy = DnsFallbackStrategy::UpstreamResolver;
        }

        let dns_strategy = self.role_state.lock().dns_strategy;
        let device = Arc::new(Device::new(config, self.callbacks(), dns_strategy)?);

        self.device.store(Some(device.clone()));
        self.no_device_waker.wake();

        // TODO: the requirement for the DNS_SENTINEL means you NEED ipv4 stack
        // we are trying to support ipv4 and ipv6, so we should have an ipv6 dns sentinel
        // alternative.
        self.add_route(DNS_SENTINEL.into())?;
        // Note: I'm just assuming this needs to succeed since we already require ipv4 stack due to the dns sentinel
        // TODO: change me when we don't require ipv4
        self.add_route(IPV4_RESOURCES.parse().unwrap())?;

        if let Err(e) = self.add_route(IPV6_RESOURCES.parse().unwrap()) {
            tracing::warn!(err = ?e, "ipv6 not supported");
        }

        self.callbacks.on_tunnel_ready()?;

        tracing::debug!("background_loop_started");

        Ok(())
    }

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&self, id: ResourceId) {
        self.role_state.lock().on_connection_failed(id);
        // self.peer_connections.lock().remove(&id.into());
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn add_route(&self, route: IpNetwork) -> connlib_shared::Result<()> {
        let maybe_new_device = self
            .device
            .load()
            .as_ref()
            .ok_or(Error::ControlProtocolError)?
            .add_route(route, self.callbacks())?;

        if let Some(new_device) = maybe_new_device {
            self.device.swap(Some(Arc::new(new_device)));
        }

        Ok(())
    }
}

/// [`Tunnel`] state specific to clients.
pub struct ClientState {
    active_candidate_receivers: StreamMap<GatewayId, RTCIceCandidate>,
    /// We split the receivers of ICE candidates into two phases because we only want to start sending them once we've received an SDP from the gateway.
    waiting_for_sdp_from_gateway: HashMap<GatewayId, Receiver<RTCIceCandidate>>,

    // TODO: Make private
    pub awaiting_connection: HashMap<ResourceId, AwaitingConnectionDetails>,
    pub gateway_awaiting_connection: HashSet<GatewayId>,

    awaiting_connection_timers: StreamMap<ResourceId, Instant>,

    pub gateway_public_keys: HashMap<GatewayId, PublicKey>,
    pub gateway_preshared_keys: HashMap<GatewayId, StaticSecret>,
    resources_gateways: HashMap<ResourceId, GatewayId>,

    pub dns_resources_internal_ips: HashMap<DnsResource, Vec<IpAddr>>,
    dns_resources: HashMap<String, ResourceDescriptionDns>,
    cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    pub resource_ids: HashMap<ResourceId, ResourceDescription>,
    pub deferred_dns_queries: HashMap<(DnsResource, Rtype), IpPacket<'static>>,

    #[allow(clippy::type_complexity)]
    pub peers_by_ip: IpNetworkTable<ConnectedPeer<GatewayId, PacketTransformClient>>,

    pub dns_strategy: DnsFallbackStrategy,
    forwarded_dns_queries: BoundedQueue<DnsQuery<'static>>,

    pub ip_provider: IpProvider,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AwaitingConnectionDetails {
    total_attemps: usize,
    response_received: bool,
    domain: Option<Dname>,
    gateways: HashSet<GatewayId>,
}

impl ClientState {
    /// Attempt to handle the given packet as a DNS packet.
    ///
    /// Returns `Ok` if the packet is in fact a DNS query with an optional response to send back.
    /// Returns `Err` if the packet is not a DNS query.
    pub(crate) fn handle_dns<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
        resolve_strategy: DnsFallbackStrategy,
    ) -> Result<Option<Packet<'a>>, MutableIpPacket<'a>> {
        match dns::parse(
            &self.dns_resources,
            &self.dns_resources_internal_ips,
            packet.as_immutable(),
            resolve_strategy,
        ) {
            Some(dns::ResolveStrategy::LocalResponse(query)) => Ok(Some(query)),
            Some(dns::ResolveStrategy::ForwardQuery(query)) => {
                self.add_pending_dns_query(query);

                Ok(None)
            }
            Some(dns::ResolveStrategy::DeferredResponse(resource)) => {
                self.on_connection_intent_dns(&resource.0);
                self.deferred_dns_queries
                    .insert(resource, packet.as_immutable().to_owned());

                Ok(None)
            }
            None => Err(packet),
        }
    }

    pub(crate) fn get_awaiting_connection_domain(
        &self,
        resource: &ResourceId,
    ) -> Result<&Option<Dname>, ConnlibError> {
        Ok(&self
            .awaiting_connection
            .get(resource)
            .ok_or(Error::UnexpectedConnectionDetails)?
            .domain)
    }

    pub(crate) fn attempt_to_reuse_connection(
        &mut self,
        resource: ResourceId,
        gateway: GatewayId,
        expected_attempts: usize,
    ) -> Result<Option<ReuseConnection>, ConnlibError> {
        let desc = self
            .resource_ids
            .get(&resource)
            .ok_or(Error::UnknownResource)?;

        let domain = self.get_awaiting_connection_domain(&resource)?.clone();

        if self.is_connected_to(resource, &self.peers_by_ip, &domain) {
            return Err(Error::UnexpectedConnectionDetails);
        }

        let details = self
            .awaiting_connection
            .get_mut(&resource)
            .ok_or(Error::UnexpectedConnectionDetails)?;

        details.response_received = true;

        if details.total_attemps != expected_attempts {
            return Err(Error::UnexpectedConnectionDetails);
        }

        if self.gateway_awaiting_connection.contains(&gateway) {
            self.awaiting_connection.remove(&resource);
            self.awaiting_connection_timers.remove(resource);
            return Err(Error::PendingConnection);
        }

        self.resources_gateways.insert(resource, gateway);

        let Some(peer) = self.peers_by_ip.iter().find_map(|(_, p)| {
            (p.inner.conn_id == gateway).then_some(ConnectedPeer {
                inner: p.inner.clone(),
                channel: p.channel.clone(),
            })
        }) else {
            self.gateway_awaiting_connection.insert(gateway);
            return Ok(None);
        };

        for ip in self.get_resource_ip(desc, &domain) {
            peer.inner.add_allowed_ip(ip);
            self.peers_by_ip.insert(
                ip,
                ConnectedPeer {
                    inner: peer.inner.clone(),
                    channel: peer.channel.clone(),
                },
            );
        }
        self.awaiting_connection.remove(&resource);
        self.awaiting_connection_timers.remove(resource);

        Ok(Some(ReuseConnection {
            resource_id: resource,
            gateway_id: gateway,
            payload: domain.clone(),
        }))
    }

    pub fn on_connection_failed(&mut self, resource: ResourceId) {
        self.awaiting_connection.remove(&resource);
        self.awaiting_connection_timers.remove(resource);

        let Some(gateway) = self.resources_gateways.remove(&resource) else {
            return;
        };
        self.gateway_awaiting_connection.remove(&gateway);
    }

    fn is_awaiting_connection_to_dns(&self, resource: &DnsResource) -> bool {
        self.awaiting_connection.contains_key(&resource.id)
    }

    pub fn on_connection_intent_dns(&mut self, resource: &DnsResource) {
        if self.is_awaiting_connection_to_dns(resource) {
            return;
        }

        tracing::trace!(?resource, "resource_connection_intent");

        const MAX_SIGNAL_CONNECTION_DELAY: Duration = Duration::from_secs(2);

        let resource_id = resource.id;

        let gateways = self
            .gateway_awaiting_connection
            .iter()
            .chain(self.resources_gateways.values())
            .copied()
            .collect();

        match self.awaiting_connection_timers.try_push(
            resource_id,
            stream::poll_fn({
                let mut interval = tokio::time::interval(MAX_SIGNAL_CONNECTION_DELAY);
                move |cx| interval.poll_tick(cx).map(Some)
            }),
        ) {
            Ok(()) => {}
            Err(PushError::BeyondCapacity(_)) => {
                tracing::warn!(%resource_id, "Too many concurrent connection attempts");
                return;
            }
            Err(PushError::Replaced(_)) => {
                // The timers are equivalent for our purpose so we don't really care about this one.
            }
        }

        self.awaiting_connection.insert(
            resource_id,
            AwaitingConnectionDetails {
                total_attemps: 0,
                response_received: false,
                domain: Some(resource.address.clone()),
                gateways,
            },
        );
    }

    pub fn on_connection_intent_ip(&mut self, destination: IpAddr) {
        if self.is_awaiting_connection_to_cidr(destination) {
            return;
        }

        tracing::trace!(resource_ip = %destination, "resource_connection_intent");

        let Some(resource) = self.get_cidr_resource_by_destination(destination) else {
            if let Some(resource) = self
                .dns_resources_internal_ips
                .iter()
                .find_map(|(r, i)| i.contains(&destination).then_some(r))
                .cloned()
            {
                self.on_connection_intent_dns(&resource);
            }
            return;
        };

        const MAX_SIGNAL_CONNECTION_DELAY: Duration = Duration::from_secs(2);

        let resource_id = resource.id();

        let gateways = self
            .gateway_awaiting_connection
            .iter()
            .chain(self.resources_gateways.values())
            .copied()
            .collect();

        match self.awaiting_connection_timers.try_push(
            resource_id,
            stream::poll_fn({
                let mut interval = tokio::time::interval(MAX_SIGNAL_CONNECTION_DELAY);
                move |cx| interval.poll_tick(cx).map(Some)
            }),
        ) {
            Ok(()) => {}
            Err(PushError::BeyondCapacity(_)) => {
                tracing::warn!(%resource_id, "Too many concurrent connection attempts");
                return;
            }
            Err(PushError::Replaced(_)) => {
                // The timers are equivalent for our purpose so we don't really care about this one.
            }
        }

        self.awaiting_connection.insert(
            resource_id,
            AwaitingConnectionDetails {
                total_attemps: 0,
                response_received: false,
                domain: None,
                gateways,
            },
        );
    }

    pub fn create_peer_config_for_new_connection(
        &mut self,
        resource: ResourceId,
        gateway: GatewayId,
        domain: &Option<Dname>,
    ) -> Result<PeerConfig, ConnlibError> {
        let shared_key = self
            .gateway_preshared_keys
            .get(&gateway)
            .ok_or(Error::ControlProtocolError)?
            .clone();

        let Some(public_key) = self.gateway_public_keys.remove(&gateway) else {
            self.awaiting_connection.remove(&resource);
            self.gateway_awaiting_connection.remove(&gateway);

            return Err(Error::ControlProtocolError);
        };

        let desc = self
            .resource_ids
            .get(&resource)
            .ok_or(Error::ControlProtocolError)?;

        let ips = self.get_resource_ip(desc, domain);

        let config = PeerConfig {
            persistent_keepalive: None,
            public_key,
            ips,
            preshared_key: SecretKey::new(Key(shared_key.to_bytes())),
        };

        // Tidy up state once everything succeeded.
        self.gateway_awaiting_connection.remove(&gateway);
        self.awaiting_connection.remove(&resource);

        Ok(config)
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.resources_gateways.get(resource).copied()
    }

    pub fn add_waiting_gateway(
        &mut self,
        id: GatewayId,
        receiver: Receiver<RTCIceCandidate>,
    ) -> StaticSecret {
        self.waiting_for_sdp_from_gateway.insert(id, receiver);
        let preshared_key = StaticSecret::random_from_rng(OsRng);
        self.gateway_preshared_keys
            .insert(id, preshared_key.clone());
        preshared_key
    }

    pub fn activate_ice_candidate_receiver(&mut self, id: GatewayId, key: PublicKey) {
        let Some(receiver) = self.waiting_for_sdp_from_gateway.remove(&id) else {
            return;
        };
        self.gateway_public_keys.insert(id, key);

        match self.active_candidate_receivers.try_push(id, receiver) {
            Ok(()) => {}
            Err(PushError::BeyondCapacity(_)) => {
                tracing::warn!("Too many active ICE candidate receivers at a time")
            }
            Err(PushError::Replaced(_)) => {
                tracing::warn!(%id, "Replaced old ICE candidate receiver with new one")
            }
        }
    }

    fn is_awaiting_connection_to_cidr(&self, destination: IpAddr) -> bool {
        let Some(resource) = self.get_cidr_resource_by_destination(destination) else {
            return false;
        };

        self.awaiting_connection.contains_key(&resource.id())
    }

    fn is_connected_to(
        &self,
        resource: ResourceId,
        connected_peers: &IpNetworkTable<ConnectedPeer<GatewayId, PacketTransformClient>>,
        domain: &Option<Dname>,
    ) -> bool {
        let Some(resource) = self.resource_ids.get(&resource) else {
            return false;
        };

        let ips = self.get_resource_ip(resource, domain);
        ips.iter()
            .any(|ip| connected_peers.exact_match(*ip).is_some())
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

    fn get_cidr_resource_by_destination(&self, destination: IpAddr) -> Option<ResourceDescription> {
        self.cidr_resources
            .longest_match(destination)
            .map(|(_, res)| ResourceDescription::Cidr(res.clone()))
    }

    fn add_pending_dns_query(&mut self, query: DnsQuery) {
        if self
            .forwarded_dns_queries
            .push_back(query.into_owned())
            .is_err()
        {
            tracing::warn!("Too many DNS queries, dropping new ones");
        }
    }
}

pub struct IpProvider {
    ipv4: Box<dyn Iterator<Item = Ipv4Addr> + Send + Sync>,
    ipv6: Box<dyn Iterator<Item = Ipv6Addr> + Send + Sync>,
}

impl IpProvider {
    fn new(ipv4: Ipv4Network, ipv6: Ipv6Network) -> Self {
        Self {
            ipv4: Box::new(ipv4.hosts()),
            ipv6: Box::new(ipv6.subnets_with_prefix(128).map(|ip| ip.network_address())),
        }
    }

    pub fn next_ipv4(&mut self) -> Option<Ipv4Addr> {
        self.ipv4.next()
    }

    pub fn next_ipv6(&mut self) -> Option<Ipv6Addr> {
        self.ipv6.next()
    }
}

impl Default for ClientState {
    fn default() -> Self {
        Self {
            active_candidate_receivers: StreamMap::new(
                Duration::from_secs(ICE_GATHERING_TIMEOUT_SECONDS),
                MAX_CONCURRENT_ICE_GATHERING,
            ),
            waiting_for_sdp_from_gateway: Default::default(),
            awaiting_connection: Default::default(),
            gateway_awaiting_connection: Default::default(),
            awaiting_connection_timers: StreamMap::new(Duration::from_secs(60), 100),
            gateway_public_keys: Default::default(),
            resources_gateways: Default::default(),
            forwarded_dns_queries: BoundedQueue::with_capacity(DNS_QUERIES_QUEUE_SIZE),
            gateway_preshared_keys: Default::default(),
            dns_strategy: Default::default(),
            // TODO: decide ip ranges
            ip_provider: IpProvider::new(
                IPV4_RESOURCES.parse().unwrap(),
                IPV6_RESOURCES.parse().unwrap(),
            ),
            dns_resources_internal_ips: Default::default(),
            dns_resources: Default::default(),
            cidr_resources: IpNetworkTable::new(),
            resource_ids: Default::default(),
            peers_by_ip: IpNetworkTable::new(),
            deferred_dns_queries: Default::default(),
        }
    }
}

impl RoleState for ClientState {
    type Id = GatewayId;

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>> {
        loop {
            match self.active_candidate_receivers.poll_next_unpin(cx) {
                Poll::Ready((conn_id, Some(Ok(c)))) => {
                    return Poll::Ready(Event::SignalIceCandidate {
                        conn_id,
                        candidate: c,
                    })
                }
                Poll::Ready((id, Some(Err(e)))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}");
                    continue;
                }
                Poll::Ready((_, None)) => continue,
                Poll::Pending => {}
            }

            match self.awaiting_connection_timers.poll_next_unpin(cx) {
                Poll::Ready((resource, Some(Ok(_)))) => {
                    let Entry::Occupied(mut entry) = self.awaiting_connection.entry(resource)
                    else {
                        self.awaiting_connection_timers.remove(resource);

                        continue;
                    };

                    if entry.get().response_received {
                        self.awaiting_connection_timers.remove(resource);

                        // entry.remove(); Maybe?

                        continue;
                    }

                    entry.get_mut().total_attemps += 1;

                    let reference = entry.get_mut().total_attemps;

                    return Poll::Ready(Event::ConnectionIntent {
                        resource: self
                            .resource_ids
                            .get(&resource)
                            .expect("inconsistent internal state")
                            .clone(),
                        connected_gateway_ids: entry.get().gateways.clone(),
                        reference,
                    });
                }

                Poll::Ready((id, Some(Err(e)))) => {
                    tracing::warn!(resource_id = %id, "Connection establishment timeout: {e}")
                }
                Poll::Ready((_, None)) => continue,
                Poll::Pending => {}
            }

            return self.forwarded_dns_queries.poll(cx).map(Event::DnsQuery);
        }
    }

    fn remove_peers(&mut self, conn_id: GatewayId) {
        self.peers_by_ip.retain(|_, p| p.inner.conn_id != conn_id);
    }

    fn refresh_peers(&mut self) -> VecDeque<Self::Id> {
        let mut peers_to_stop = VecDeque::new();
        for (_, peer) in self.peers_by_ip.iter().unique_by(|(_, p)| p.inner.conn_id) {
            let conn_id = peer.inner.conn_id;

            let bytes = match peer.inner.update_timers() {
                Ok(Some(bytes)) => bytes,
                Ok(None) => continue,
                Err(e) => {
                    tracing::error!("Failed to update timers for peer: {e}");
                    if e.is_fatal_connection_error() {
                        peers_to_stop.push_back(conn_id);
                    }

                    continue;
                }
            };

            let peer_channel = peer.channel.clone();

            tokio::spawn(async move {
                if let Err(e) = peer_channel.send(bytes).await {
                    tracing::error!("Failed to send packet to peer: {e:#}");
                }
            });
        }

        peers_to_stop
    }
}
