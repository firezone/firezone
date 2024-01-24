use crate::bounded_queue::BoundedQueue;
use crate::device_channel::{Device, Packet};
use crate::ip_packet::{IpPacket, MutableIpPacket};
use crate::peer::PacketTransformClient;
use crate::sockets::UdpSockets;
use crate::{
    dns, ConnectedPeer, DnsQuery, Event, PeerConfig, RoleState, Tunnel, DNS_QUERIES_QUEUE_SIZE,
    ICE_GATHERING_TIMEOUT_SECONDS, MAX_CONCURRENT_ICE_GATHERING, MAX_UDP_SIZE,
};
use bimap::BiMap;
use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::{
    DnsServer, GatewayId, Interface as InterfaceConfig, Key, ResourceDescription,
    ResourceDescriptionCidr, ResourceDescriptionDns, ResourceId, ReuseConnection, SecretKey,
};
use connlib_shared::{Callbacks, Dname, IpProvider};
use domain::base::Rtype;
use firezone_connection::{ClientConnectionPool, ConnectionPool};
use futures::stream;
use futures_bounded::{FuturesMap, PushError, StreamMap};
use futures_util::FutureExt;
use hickory_resolver::lookup::Lookup;
use if_watch::tokio::IfWatcher;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use itertools::Itertools;

use rand_core::OsRng;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet, VecDeque};
use std::net::IpAddr;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::time::{Instant, Interval, MissedTickBehavior};

// Using str here because Ipv4/6Network doesn't support `const` 🙃
const IPV4_RESOURCES: &str = "100.96.0.0/11";
const IPV6_RESOURCES: &str = "fd00:2021:1111:8000::/107";
const MAX_CONNECTION_REQUEST_DELAY: Duration = Duration::from_secs(10);

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
        if self
            .role_state
            .lock()
            .resource_ids
            .contains_key(&resource_description.id())
        {
            // TODO
            tracing::info!("Resource updates aren't implemented yet");
            return Ok(());
        }

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

        let mut resource_descriptions = {
            let mut role_state = self.role_state.lock();
            role_state
                .resource_ids
                .insert(resource_description.id(), resource_description);
            role_state
                .resource_ids
                .values()
                .cloned()
                .collect::<Vec<_>>()
        };
        sort_resources(&mut resource_descriptions);

        self.callbacks.on_update_resources(resource_descriptions)?;
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
    pub fn set_interface(
        &self,
        config: &InterfaceConfig,
        dns_mapping: BiMap<IpAddr, DnsServer>,
    ) -> connlib_shared::Result<()> {
        let device = Arc::new(Device::new(
            config,
            // We can just sort in here because sentinel ips are created in order
            dns_mapping.left_values().copied().sorted().collect(),
            self.callbacks(),
        )?);

        self.device.store(Some(device.clone()));
        self.no_device_waker.wake();

        let mut errs = Vec::new();
        for sentinel in dns_mapping.left_values() {
            if let Err(e) = self.add_route((*sentinel).into()) {
                tracing::warn!(err = ?e, %sentinel , "couldn't add route for sentinel");
                errs.push(e);
            }
        }

        if errs.len() == dns_mapping.left_values().len() && dns_mapping.left_values().len() > 0 {
            return Err(errs.pop().unwrap());
        }

        self.role_state.lock().dns_mapping = dns_mapping;

        let res_v4 = self.add_route(IPV4_RESOURCES.parse().unwrap());
        let res_v6 = self.add_route(IPV6_RESOURCES.parse().unwrap());
        res_v4.or(res_v6)?;

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
    // TODO: Make private
    pub awaiting_connection: HashMap<ResourceId, AwaitingConnectionDetails>,
    awaiting_connection_timers: StreamMap<ResourceId, Instant>,

    pub gateway_awaiting_connection: HashSet<GatewayId>,
    // This timer exist for an unlikely case, on unreliable connections where the RequestConnection message
    // or the response is lost:
    // This would remove the "PendingConnection" message and be able to try the connection again.
    // There are some edge cases that come with this:
    // * a gateway in a VERY unlikely case could receive the connection request twice. This will stop any connection attempt and make the whole thing start again.
    // if this would happen often the UX would be awful but this is only in cases where messages are delayed for more than 10 seconds, it's enough that it doesn't break correctness.
    // * even more unlikely a tunnel could be established in a sort of race condition when this timer goes off. Again a similar behavior to the one above will happen, the webrtc connection will be forcefully terminated from the gateway.
    // then the old peer will expire, this might take ~180 seconds. This is an even worse experience but the likelihood of this happen is infinitesimaly small, again correctness is the only important part.
    gateway_awaiting_connection_timers: FuturesMap<GatewayId, ()>,

    pub gateway_public_keys: HashMap<GatewayId, PublicKey>,
    pub gateway_preshared_keys: HashMap<GatewayId, StaticSecret>,
    resources_gateways: HashMap<ResourceId, GatewayId>,

    pub dns_resources_internal_ips: HashMap<DnsResource, HashSet<IpAddr>>,
    dns_resources: HashMap<String, ResourceDescriptionDns>,
    cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    pub resource_ids: HashMap<ResourceId, ResourceDescription>,
    pub deferred_dns_queries: HashMap<(DnsResource, Rtype), IpPacket<'static>>,

    #[allow(clippy::type_complexity)]
    pub peers_by_ip: IpNetworkTable<ConnectedPeer<GatewayId, PacketTransformClient>>,

    forwarded_dns_queries: BoundedQueue<DnsQuery<'static>>,

    pub ip_provider: IpProvider,

    refresh_dns_timer: Interval,

    pub dns_mapping: BiMap<IpAddr, DnsServer>,

    pub connection_pool: ClientConnectionPool<GatewayId>,
    if_watcher: IfWatcher,
    udp_sockets: UdpSockets<MAX_UDP_SIZE>,
    relay_socket: tokio::net::UdpSocket,
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
    ) -> Result<Option<Packet<'a>>, (MutableIpPacket<'a>, IpAddr)> {
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
                self.on_connection_intent_dns(&resource.0);
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
            match self
                .gateway_awaiting_connection_timers
                // Note: we don't need to set a timer here because
                // the FutureMap already expires things, it seems redundant
                // to also have timer that expires.
                .try_push(gateway, std::future::pending())
            {
                Ok(_) => {}
                Err(PushError::BeyondCapacity(_)) => {
                    tracing::warn!(%gateway, "Too many concurrent connection attempts");
                    return Err(Error::TooManyConnectionRequests);
                }
                Err(PushError::Replaced(_)) => {
                    // The timers are equivalent for our purpose so we don't really care about this one.
                }
            };
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
        self.gateway_awaiting_connection_timers.remove(gateway);
    }

    fn is_awaiting_connection_to_dns(&self, resource: &DnsResource) -> bool {
        self.awaiting_connection.contains_key(&resource.id)
    }

    pub fn on_connection_intent_dns(&mut self, resource: &DnsResource) {
        if self.is_awaiting_connection_to_dns(resource) {
            return;
        }

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
        self.gateway_awaiting_connection_timers.remove(gateway);
        self.awaiting_connection.remove(&resource);

        Ok(config)
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.resources_gateways.get(resource).copied()
    }

    pub fn activate_ice_candidate_receiver(&mut self, id: GatewayId, key: PublicKey) {
        self.gateway_public_keys.insert(id, key);
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

impl Default for ClientState {
    fn default() -> Self {
        // With this single timer this might mean that some DNS are refreshed too often
        // however... this also mean any resource is refresh within a 5 mins interval
        // therefore, only the first time it's added that happens, after that it doesn't matter.
        let mut interval = tokio::time::interval(Duration::from_secs(300));
        interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
        let if_watcher = IfWatcher::new().expect(
            "Program should be able to list interfaces on the system. Check binary's permissions",
        );
        let mut connection_pool = ConnectionPool::new(
            StaticSecret::random_from_rng(OsRng),
            std::time::Instant::now(),
        );
        let mut udp_sockets = UdpSockets::default();

        for ip in if_watcher.iter() {
            tracing::info!(address = %ip.addr(), "New local interface address found");
            match udp_sockets.bind((ip.addr(), 0)) {
                Ok(addr) => connection_pool.add_local_interface(addr),
                Err(e) => {
                    tracing::debug!(address = %ip.addr(), err = ?e, "Couldn't bind socket to interface: {e:#?}")
                }
            }
        }

        let relay_socket = tokio::net::UdpSocket::bind("0.0.0.0:0")
            .now_or_never()
            .expect("binding to `SocketAddr` is not async")
            // Note: We could relax this condition
            .expect("Program should be able to bind to 0.0.0.0:0 to be able to connect to relays");

        Self {
            awaiting_connection: Default::default(),
            awaiting_connection_timers: StreamMap::new(Duration::from_secs(60), 100),

            gateway_awaiting_connection: Default::default(),
            gateway_awaiting_connection_timers: FuturesMap::new(MAX_CONNECTION_REQUEST_DELAY, 100),

            gateway_public_keys: Default::default(),
            resources_gateways: Default::default(),
            forwarded_dns_queries: BoundedQueue::with_capacity(DNS_QUERIES_QUEUE_SIZE),
            gateway_preshared_keys: Default::default(),
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
            refresh_dns_timer: interval,
            dns_mapping: Default::default(),
            connection_pool,
            if_watcher,
            udp_sockets,
            relay_socket,
        }
    }
}

impl RoleState for ClientState {
    type Id = GatewayId;

    fn add_remote_candidate(&mut self, conn_id: GatewayId, ice_candidate: String) {
        self.connection_pool
            .add_remote_candidate(conn_id, ice_candidate);
    }

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>> {
        loop {
            while let Some(transmit) = self.connection_pool.poll_transmit() {
                if let Err(e) = match transmit.src {
                    Some(src) => self
                        .udp_sockets
                        .try_send_to(src, transmit.dst, &transmit.payload),
                    None => self
                        .relay_socket
                        .try_send_to(&transmit.payload, transmit.dst),
                } {
                    tracing::warn!(src = ?transmit.src, dst = %transmit.dst, "Failed to send UDP packet: {e:#?}");
                }
            }

            match self.connection_pool.poll_event() {
                Some(firezone_connection::Event::SignalIceCandidate {
                    connection,
                    candidate,
                }) => {
                    return Poll::Ready(Event::SignalIceCandidate {
                        conn_id: connection,
                        candidate,
                    })
                }
                Some(firezone_connection::Event::ConnectionEstablished(id)) => todo!(),
                Some(firezone_connection::Event::ConnectionFailed(id)) => todo!(),
                None => {}
            }

            if let Poll::Ready((gateway_id, _)) =
                self.gateway_awaiting_connection_timers.poll_unpin(cx)
            {
                self.gateway_awaiting_connection.remove(&gateway_id);
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
                    tracing::warn!(resource_id = %id, "Connection establishment timeout: {e}");
                    self.awaiting_connection.remove(&id);
                    self.awaiting_connection_timers.remove(id);
                }
                Poll::Ready((_, None)) => continue,
                Poll::Pending => {}
            }

            if self.refresh_dns_timer.poll_tick(cx).is_ready() {
                let mut connections = Vec::new();

                self.peers_by_ip
                    .iter()
                    .for_each(|p| p.1.inner.transform.expire_dns_track());

                for resource in self.dns_resources_internal_ips.keys() {
                    let Some(gateway_id) = self.resources_gateways.get(&resource.id) else {
                        continue;
                    };
                    // filter inactive connections
                    if !self
                        .peers_by_ip
                        .iter()
                        .any(|(_, p)| &p.inner.conn_id == gateway_id)
                    {
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

            match self.if_watcher.poll_if_event(cx) {
                Poll::Ready(Ok(ev)) => match ev {
                    if_watch::IfEvent::Up(ip) => {
                        tracing::info!(address = %ip.addr(), "New local interface address found");
                        match self.udp_sockets.bind((ip.addr(), 0)) {
                            Ok(addr) => self.connection_pool.add_local_interface(addr),
                            Err(e) => {
                                tracing::debug!(address = %ip.addr(), err = ?e, "Couldn't bind socket to interface: {e:#?}")
                            }
                        }
                    }
                    if_watch::IfEvent::Down(ip) => {
                        tracing::info!(address = %ip.addr(), "Interface IP no longer available");
                        todo!()
                    }
                },
                Poll::Ready(Err(e)) => {
                    tracing::debug!("Error while polling interfces: {e:#?}");
                }
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

            // TODO:
            // let bytes = match peer.inner.update_timers() {
            //     Ok(Some(bytes)) => bytes,
            //     Ok(None) => continue,
            //     Err(e) => {
            //         tracing::error!("Failed to update timers for peer: {e}");
            //         if e.is_fatal_connection_error() {
            //             peers_to_stop.push_back(conn_id);
            //         }

            //         continue;
            //     }
            // };

            let peer_channel = peer.channel.clone();

            tokio::spawn(async move {
                if let Err(e) = peer_channel.send(todo!()).await {
                    tracing::error!("Failed to send packet to peer: {e:#}");
                }
            });
        }

        peers_to_stop
    }
}

/// Sorts `resource_descriptions` in-place alphabetically
fn sort_resources(resource_descriptions: &mut [ResourceDescription]) {
    // Unstable sort is slightly faster, and we use the ID as a tie-break,
    // so stability should not matter much
    resource_descriptions.sort_unstable_by(|a, b| (a.name(), a.id()).cmp(&(b.name(), b.id())));
}

#[cfg(test)]
mod tests {
    use connlib_shared::messages::{ResourceDescription, ResourceDescriptionDns, ResourceId};
    use std::str::FromStr;

    fn fake_resource(name: &str, uuid: &str) -> ResourceDescription {
        ResourceDescription::Dns(ResourceDescriptionDns {
            id: ResourceId::from_str(uuid).unwrap(),
            name: name.to_string(),
            address: "unused.example.com".to_string(),
        })
    }

    #[test]
    fn sort_resources_normal() {
        let cloudflare = fake_resource("Cloudflare DNS", "2efe9c25-bd92-49a0-99d7-8b92da014dd5");
        let example = fake_resource("Example", "613eaf56-6efa-45e5-88aa-ea4ad64d8c18");
        let fast = fake_resource("Fast.com", "624b7154-08f6-4c9e-bac0-c3a587fc9322");
        let metabase_1 = fake_resource("Metabase", "98ee1682-8192-4f15-b4a6-03178dfa7f95");
        let metabase_2 = fake_resource("Metabase", "e431d1b8-afc2-4f93-95c2-0d15413f5422");
        let ifconfig = fake_resource("ifconfig.net", "6b7188f5-00ac-41dc-9ddd-57e2384f31ef");
        let ten = fake_resource("10", "9d1907cc-0693-4063-b388-4d29524e2514");
        let nine = fake_resource("9", "a7b66f28-9cd1-40fc-bdc4-4763ed92ea41");
        let emoji = fake_resource("🫠", "7d08cfca-8737-4c5e-a88e-e92574657217");

        let mut resource_descriptions = vec![
            nine.clone(),
            ten.clone(),
            fast.clone(),
            ifconfig.clone(),
            emoji.clone(),
            example.clone(),
            cloudflare.clone(),
            metabase_2.clone(),
            metabase_1.clone(),
        ];

        super::sort_resources(&mut resource_descriptions);

        let expected = vec![
            // Numbers first
            // Numbers are sorted byte-wise, if they don't use leading zeroes
            // they won't be in numeric order
            ten.clone(),
            nine.clone(),
            // Then uppercase, in alphabetical order
            cloudflare.clone(),
            example.clone(),
            fast.clone(),
            // UUIDs tie-break if the names are identical
            metabase_1.clone(),
            metabase_2.clone(),
            // Lowercase comes after all uppercase are done
            ifconfig.clone(),
            // Emojis start with a leading '1' bit, so they come after all
            // [Basic Latin](https://en.wikipedia.org/wiki/Basic_Latin_\(Unicode_block\)) chars
            emoji.clone(),
        ];

        assert!(
            resource_descriptions == expected,
            "Actual: {:#?}\nExpected: {:#?}",
            resource_descriptions,
            expected
        );
    }
}
