use crate::bounded_queue::BoundedQueue;
use crate::connection::{Connecting, Connection, DirectClientToGateway, WantsRemoteCredentials};
use crate::device_channel::Device;
use crate::index::IndexLfsr;
use crate::ip_packet::IpPacket;
use crate::rate_limiter::RateLimiter;
use crate::shared_utils::{
    poll_allocations, poll_bindings, update_candidates_of_connections, upsert_relays,
};
use crate::{
    connection, device_channel, dns, DnsFallbackStrategy, Transmit, Tunnel, DNS_QUERIES_QUEUE_SIZE,
    MAX_UDP_SIZE,
};
use boringtun::noise::Tunn;
use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::{
    GatewayId, Interface as InterfaceConfig, Relay, ResourceDescription, ResourceDescriptionCidr,
    ResourceDescriptionDns, ResourceId, ReuseConnection, SecretKey,
};
use connlib_shared::{Callbacks, Dname, DNS_SENTINEL};
use domain::base::Rtype;
use either::Either;
use firezone_relay::client::{Allocation, Binding};
use hickory_resolver::lookup::Lookup;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use secrecy::ExposeSecret;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::task::{Context, Poll};
use std::time::Duration;
use str0m::ice::IceCreds;
use str0m::Candidate;

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

impl<CB> Tunnel<CB, State>
where
    CB: Callbacks + 'static,
{
    /// Adds a the given resource to the tunnel.
    ///
    /// Once added, when a packet for the resource is intercepted a new data channel will be created
    /// and packets will be wrapped with wireguard and sent through it.
    pub fn add_resource(
        &self,
        resource_description: ResourceDescription,
    ) -> connlib_shared::Result<()> {
        match &resource_description {
            ResourceDescription::Dns(dns) => {
                tracing::trace!(address = %dns.address, name = %dns.name, "Adding DNS resource");

                self.role_state
                    .lock()
                    .dns_resources
                    .insert(dns.address.clone(), dns.clone());
            }
            ResourceDescription::Cidr(cidr) => {
                tracing::trace!(address = %cidr.address, name = %cidr.name, "Adding CIDR resource");

                self.add_route(cidr.address)?;

                self.role_state
                    .lock()
                    .cidr_resources
                    .insert(cidr.address, cidr.clone());
            }
        }

        let mut role_state = self.role_state.lock();
        role_state
            .resources_by_id
            .insert(resource_description.id(), resource_description);
        self.callbacks
            .on_update_resources(role_state.resources_by_id.values().cloned().collect())?;
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
            let guard = self.device.lock();
            let Some(device) = guard.as_ref() else {
                return Ok(());
            };

            device.write(pkt)?;
        }

        Ok(())
    }

    pub fn set_interface(&self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        let device = Device::new(config, self.callbacks(), DnsFallbackStrategy::default())?;

        *self.device.lock() = Some(device);
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

        tracing::info!("Configured new device");

        Ok(())
    }

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&self, id: ResourceId) {
        self.role_state.lock().on_connection_failed(id);
        // self.peer_connections.lock().remove(&id.into());
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn add_route(&self, route: IpNetwork) -> connlib_shared::Result<()> {
        let mut guard = self.device.lock();

        if let Some(new_device) = guard
            .as_ref()
            .ok_or(Error::ControlProtocolError)?
            .add_route(route, self.callbacks())?
        {
            *guard = Some(new_device);
        }

        Ok(())
    }
}

/// [`Tunnel`] state specific to clients.
pub struct State {
    next_index: IndexLfsr,
    rate_limiter: RateLimiter,
    tunnel_private_key: StaticSecret,

    // TODO: Use `Either<Binding, Allocation>` here because we will never use the same server as STUN _and_ TURN?
    bindings: HashMap<SocketAddr, Binding>,
    allocations: HashMap<SocketAddr, Allocation>,

    awaiting_connection: HashMap<ResourceId, AwaitingConnectionDetails>,
    initial_connections: HashMap<GatewayId, Connection<WantsRemoteCredentials>>,
    pending_connections: HashMap<GatewayId, Connection<Connecting>>,
    established_connections: HashMap<GatewayId, Connection<DirectClientToGateway>>,

    dns_resources_internal_ips: HashMap<DnsResource, Vec<IpAddr>>,
    dns_resources: HashMap<String, ResourceDescriptionDns>,
    cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,

    resources_by_id: HashMap<ResourceId, ResourceDescription>,

    dns_strategy: DnsFallbackStrategy,
    forwarded_dns_queries: BoundedQueue<dns::Query<'static>>,
    deferred_dns_queries: HashMap<(DnsResource, Rtype), Vec<u8>>,

    /// Which gateway we should use for a particular resource **by the resource's ID**.
    gateways_by_resource_id: HashMap<ResourceId, GatewayId>,
    /// Which gateway we should use for a particular resource **by the resource's IP**.
    gateways_by_resource_ip: IpNetworkTable<GatewayId>,
    gateways_by_socket: HashMap<SocketAddr, GatewayId>,

    update_timer_interval: tokio::time::Interval,

    /// A re-usable buffer for en/de-capsulating packets.
    buf: [u8; MAX_UDP_SIZE],
    /// Events we've buffered to be returned to the [`Tunnel`].
    pending_events: BoundedQueue<Either<Event, Transmit>>,

    ip_provider: IpProvider,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AwaitingConnectionDetails {
    total_attemps: usize,
    response_received: bool,
    gateways: HashSet<GatewayId>,
    domain: Option<Dname>,
}

impl State {
    /// Attempt to handle the given packet as a DNS packet.
    ///
    /// Returns `Ok` if the packet is in fact a DNS query with an optional response to send back.
    /// Returns `Err` if the packet is not a DNS query.
    pub(crate) fn handle_dns<'a>(
        &mut self,
        packet: &'a [u8],
        resolve_strategy: DnsFallbackStrategy,
    ) -> Result<Option<device_channel::Packet<'a>>, ()> {
        match dns::parse(
            &self.dns_resources,
            &self.dns_resources_internal_ips,
            packet,
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
                    .insert(resource, packet.to_owned());

                Ok(None)
            }
            None => Err(()),
        }
    }

    pub(crate) fn get_awaiting_connection_domain(
        &self,
        resource: &ResourceId,
    ) -> Result<Option<Dname>, ConnlibError> {
        Ok(self
            .awaiting_connection
            .get(resource)
            .ok_or(Error::UnexpectedConnectionDetails)?
            .domain
            .clone())
    }

    pub(crate) fn attempt_to_reuse_connection(
        &mut self,
        resource: ResourceId,
        gateway: GatewayId,
    ) -> Result<Option<ReuseConnection>, ConnlibError> {
        tracing::trace!("Attempting to reuse connection");

        let desc = self
            .resources_by_id
            .get(&resource)
            .ok_or(Error::UnknownResource)?;

        let domain = self.get_awaiting_connection_domain(&resource)?;

        if self.is_connected_to(resource, &domain) {
            return Err(Error::UnexpectedConnectionDetails);
        }

        if self.pending_connections.contains_key(&gateway)
            || self.initial_connections.contains_key(&gateway)
        {
            // TODO: Also established?
            return Err(Error::PendingConnection);
        }

        self.gateways_by_resource_id.insert(resource, gateway);

        let ips = self.get_resource_ip(desc, &domain);

        let Some(connection) = self.established_connections.get_mut(&gateway) else {
            return Ok(None);
        };

        for ip in ips {
            connection.add_allowed_ip(ip);
            self.gateways_by_resource_ip.insert(ip, gateway);
        }

        Ok(Some(ReuseConnection {
            resource_id: resource,
            gateway_id: gateway,
            payload: domain,
        }))
    }

    pub(crate) fn on_connection_failed(&mut self, resource: ResourceId) {
        let Some(gateway) = self.gateways_by_resource_id.remove(&resource) else {
            return;
        };
        self.initial_connections.remove(&gateway);
        self.pending_connections.remove(&gateway);
    }

    fn is_awaiting_connection_to_dns(&self, resource: &DnsResource) -> bool {
        let Some(gateway) = self.gateways_by_resource_id.get(&resource.id) else {
            return false;
        };

        self.initial_connections.contains_key(gateway)
            || self.pending_connections.contains_key(gateway)
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn on_connection_intent_dns(&mut self, resource: &DnsResource) {
        if self.is_awaiting_connection_to_dns(resource) {
            tracing::trace!("Already establishing connection to resource");
            return;
        }

        tracing::trace!("resource_connection_intent");

        let gateways = self
            .awaiting_connection
            .values()
            .flat_map(|ac| ac.gateways.iter())
            .chain(self.gateways_by_resource_id.values())
            .copied()
            .collect::<HashSet<_>>();

        tracing::trace!(?gateways);

        let _ = self
            .pending_events
            .push_back(Either::Left(Event::ConnectionIntent {
                resource_id: resource.id,
                connected_gateway_ids: gateways.clone(),
            }));
        self.awaiting_connection.insert(
            resource.id,
            AwaitingConnectionDetails {
                total_attemps: 0,
                response_received: false,
                domain: None,
                gateways,
            },
        );
    }

    fn on_connection_intent_ip(&mut self, destination: IpAddr) {
        if self.is_awaiting_connection_to_cidr(destination) {
            tracing::trace!("Already establishing connection to resource");
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

        let gateways = self
            .awaiting_connection
            .values()
            .flat_map(|ac| ac.gateways.iter())
            .chain(self.gateways_by_resource_id.values())
            .copied()
            .collect::<HashSet<_>>();

        tracing::trace!(?gateways);

        let _ = self
            .pending_events
            .push_back(Either::Left(Event::ConnectionIntent {
                resource_id: resource.id(),
                connected_gateway_ids: gateways.clone(),
            }));

        self.awaiting_connection.insert(
            resource.id(),
            AwaitingConnectionDetails {
                total_attemps: 0,
                response_received: false,
                domain: None,
                gateways,
            },
        );
    }

    fn is_awaiting_connection_to_cidr(&self, destination: IpAddr) -> bool {
        let Some(resource) = self.get_cidr_resource_by_destination(destination) else {
            return false;
        };

        self.awaiting_connection.contains_key(&resource.id())
    }

    fn is_connected_to(&self, resource: ResourceId, domain: &Option<Dname>) -> bool {
        let Some(resource) = self.resources_by_id.get(&resource) else {
            return false;
        };

        let ips = self.get_resource_ip(resource, domain);
        ips.iter()
            .any(|ip| self.gateways_by_resource_ip.exact_match(*ip).is_some())
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

    fn add_pending_dns_query(&mut self, query: dns::Query) {
        if self
            .forwarded_dns_queries
            .push_back(query.into_owned())
            .is_err()
        {
            tracing::warn!("Too many DNS queries, dropping new ones");
        }
    }

    pub(crate) fn make_new_connection(
        &mut self,
        local: SocketAddr,
        id: GatewayId,
        relays: Vec<Relay>,
    ) -> (SecretKey, IceCreds) {
        tracing::trace!("Creating new connection");

        let (stun_servers, turn_servers) =
            upsert_relays(&mut self.bindings, &mut self.allocations, relays);

        let connection = Connection::new_client_to_gateway(local, stun_servers, turn_servers);

        let preshared_key = connection.preshared_key();
        let ice_creds = connection.ice_credentials();

        self.initial_connections.insert(id, connection);
        self.pending_events.extend(
            update_candidates_of_connections(
                self.bindings.iter(),
                self.allocations.iter(),
                &mut self.initial_connections,
                &mut self.pending_connections,
            )
            .map(|(conn_id, candidate)| {
                Either::Left(Event::SignalIceCandidate { conn_id, candidate })
            }),
        );

        (preshared_key, ice_creds)
    }

    #[tracing::instrument(level = "debug", skip(self, gateway_public_key), fields(gateway, public_key = %hex::encode(gateway_public_key.to_bytes())))]
    pub(crate) fn set_remote_credentials(
        &mut self,
        resource: ResourceId,
        gateway_public_key: PublicKey,
        remote_credentials: IceCreds,
    ) -> Result<(), Error> {
        let gateway = self
            .gateway_by_resource(&resource)
            .ok_or(Error::UnknownResource)?;

        tracing::Span::current().record("gateway", tracing::field::display(&gateway));

        let connection = self
            .initial_connections
            .remove(&gateway)
            .ok_or(Error::Other("no ice agent for gateway"))?;

        let connection = connection.with_remote_credentials(gateway_public_key, remote_credentials);

        self.pending_connections.insert(gateway, connection);

        Ok(())
    }

    pub(crate) fn add_remote_candidate(&mut self, gateway: GatewayId, candidate: Candidate) {
        let Some(agent) = self.pending_connections.get_mut(&gateway) else {
            return;
        };

        agent.add_remote_candidate(candidate);
    }

    /// Handles an incoming datagram from the given sender.
    ///
    /// TODO
    #[tracing::instrument(level = "trace", skip(self, packet, sender), fields(src = %sender, num_bytes = %packet.len()))]
    pub(crate) fn handle_socket_input<'b>(
        &'b mut self,
        sender: SocketAddr,
        packet: &'b [u8],
    ) -> Option<device_channel::Packet<'b>> {
        if let Some(binding) = self.bindings.get_mut(&sender) {
            if binding.handle_input(sender, packet) {
                self.pending_events.extend(
                    update_candidates_of_connections(
                        self.bindings.iter(),
                        self.allocations.iter(),
                        &mut self.initial_connections,
                        &mut self.pending_connections,
                    )
                    .map(|(conn_id, candidate)| {
                        Either::Left(Event::SignalIceCandidate { conn_id, candidate })
                    }),
                );
                return None;
            }
        }

        if let Some(allocation) = self.allocations.get_mut(&sender) {
            if allocation.handle_input(sender, packet) {
                self.pending_events.extend(
                    update_candidates_of_connections(
                        self.bindings.iter(),
                        self.allocations.iter(),
                        &mut self.initial_connections,
                        &mut self.pending_connections,
                    )
                    .map(|(conn_id, candidate)| {
                        Either::Left(Event::SignalIceCandidate { conn_id, candidate })
                    }),
                );
                return None;
            }
        }

        for connection in self.pending_connections.values_mut() {
            if connection.handle_input(sender, packet) {
                return None;
            }
        }

        for connection in self.established_connections.values_mut() {
            if connection.accepts(sender, packet) {
                match connection.decapsulate(sender, packet, &mut self.buf) {
                    Ok(maybe_packet) => return maybe_packet,
                    Err(e) => {
                        todo!("{e}")
                    }
                }
            }
        }

        None
    }

    /// Handles an incoming datagram from the device.
    ///
    /// TODO
    #[tracing::instrument(level = "trace", skip(self, packet), fields(dst, num_bytes = %packet.len()))]
    pub(crate) fn handle_device_input<'a, 'b>(
        &'a mut self,
        packet: &'b mut [u8],
    ) -> Option<Either<device_channel::Packet<'b>, (SocketAddr, &'a [u8])>> {
        match self.handle_dns(packet, self.dns_strategy) {
            Ok(Some(response)) => return Some(Either::Left(response)),
            Ok(None) => return None,
            Err(()) => {}
        };

        let addr = IpPacket::new(packet)?.destination();
        tracing::Span::current().record("dst", tracing::field::display(&addr));

        let Some((_, gateway)) = self.gateways_by_resource_ip.longest_match(addr) else {
            self.on_connection_intent_ip(addr);
            return None;
        };

        let peer = self.established_connections.get_mut(gateway)?; // TODO: Better error logging on inconsistent state?

        match peer.encapsulate(packet, &mut self.buf).transpose()? {
            Ok((dst, bytes)) => Some(Either::Right((dst, bytes))),
            Err(e) => {
                tracing::warn!("Failed to encapsulate packet: {e}");
                None
            }
        }
    }

    pub(crate) fn poll_next_event(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Either<Event, Transmit>> {
        if let Poll::Ready(event) = self.pending_events.poll(cx) {
            return Poll::Ready(event);
        }

        if let Poll::Ready(transmit) = poll_bindings(self.bindings.values_mut(), cx) {
            return Poll::Ready(Either::Right(transmit.into()));
        }

        if let Poll::Ready(transmit) = poll_allocations(self.allocations.values_mut(), cx) {
            return Poll::Ready(Either::Right(transmit.into()));
        }

        'outer: for gateway in self.pending_connections.keys().copied().collect::<Vec<_>>() {
            let Entry::Occupied(mut entry) = self.pending_connections.entry(gateway) else {
                unreachable!("ID comes from list")
            };

            let connection = entry.get_mut();

            loop {
                match connection.poll(cx) {
                    Poll::Ready(connection::ConnectingEvent::Connection { src, dst }) => {
                        let connection = entry.remove().into_established_client_to_gateway(
                            src,
                            dst,
                            self.new_tunnel_fn(),
                        );

                        self.gateways_by_socket.insert(dst, gateway);
                        self.established_connections.insert(gateway, connection);
                        continue 'outer;
                    }
                    Poll::Ready(connection::ConnectingEvent::WantChannelToPeer { relay, peer }) => {
                        let Some(allocation) = self.allocations.get_mut(&relay) else {
                            debug_assert!(
                                false,
                                "Connection wants channel to relay without allocation"
                            );
                            continue;
                        };

                        let binding = allocation
                            .bind_channel(peer)
                            .expect("allocation is always ready if we want to bind a channel");
                        connection.add_binding(relay, binding);

                        continue;
                    }
                    Poll::Ready(connection::ConnectingEvent::Transmit(transmit)) => {
                        return Poll::Ready(Either::Right(transmit));
                    }
                    Poll::Pending => break,
                }
            }
        }

        if self.update_timer_interval.poll_tick(cx).is_ready() {
            for connection in self.established_connections.values_mut() {
                connection.update_timers();
            }
        }

        for connection in self.established_connections.values_mut() {
            while let Some(transmit) = connection.poll_transmit() {
                let _ = self.pending_events.push_back(Either::Right(transmit));
            }
        }

        if let Poll::Ready(query) = self.forwarded_dns_queries.poll(cx) {
            return Poll::Ready(Either::Left(Event::DnsQuery(query)));
        }

        let _ = self.rate_limiter.poll(cx);

        Poll::Pending
    }

    fn new_tunnel_fn(&mut self) -> impl FnOnce(SecretKey, PublicKey) -> Tunn + '_ {
        |secret, public| {
            Tunn::new(
                self.tunnel_private_key.clone(),
                public,
                Some(secret.expose_secret().0),
                None,
                self.next_index.next(),
                Some(self.rate_limiter.clone_to()),
            )
        }
    }

    fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.gateways_by_resource_id.get(resource).copied()
    }

    pub(crate) fn new(tunnel_private_key: StaticSecret) -> Self {
        Self {
            next_index: Default::default(),
            rate_limiter: RateLimiter::new((&tunnel_private_key).into()),
            tunnel_private_key,
            bindings: Default::default(),
            allocations: Default::default(),
            awaiting_connection: Default::default(),
            initial_connections: Default::default(),
            pending_connections: Default::default(),
            established_connections: Default::default(),
            dns_resources_internal_ips: Default::default(),
            dns_resources: Default::default(),
            cidr_resources: IpNetworkTable::new(),
            resources_by_id: Default::default(),
            gateways_by_resource_id: Default::default(),
            gateways_by_resource_ip: IpNetworkTable::new(),
            gateways_by_socket: Default::default(),
            forwarded_dns_queries: BoundedQueue::with_capacity(DNS_QUERIES_QUEUE_SIZE),
            pending_events: BoundedQueue::with_capacity(1000), // Really this should never fill up!
            buf: [0u8; MAX_UDP_SIZE],
            update_timer_interval: tokio::time::interval(Duration::from_secs(1)),
            dns_strategy: Default::default(),
            deferred_dns_queries: Default::default(),
            // TODO: decide ip ranges
            ip_provider: IpProvider::new(
                IPV4_RESOURCES.parse().unwrap(),
                IPV6_RESOURCES.parse().unwrap(),
            ),
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

pub enum Event {
    SignalIceCandidate {
        conn_id: GatewayId,
        candidate: Candidate,
    },
    ConnectionIntent {
        resource_id: ResourceId,
        connected_gateway_ids: HashSet<GatewayId>,
    },
    DnsQuery(dns::Query<'static>),
}
