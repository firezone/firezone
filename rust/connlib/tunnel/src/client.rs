use crate::control_protocol::new_peer_connection;
use crate::device_channel::{create_iface, Packet};
use crate::ip_packet::{IpPacket, MutableIpPacket};
use crate::resource_table::ResourceTable;
use crate::{
    dns, ConnectedPeer, DnsQuery, PeerConfig, RoleState, Tunnel, DNS_QUERIES_QUEUE_SIZE,
    ICE_GATHERING_TIMEOUT_SECONDS, MAX_CONCURRENT_ICE_GATHERING,
};
use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::{
    DnsServer, GatewayId, Interface as InterfaceConfig, IpDnsServer, Key, Relay,
    ResourceDescription, ResourceId, SecretKey,
};
use connlib_shared::{Callbacks, DNS_SENTINEL};
use either::Either;
use futures::channel::{mpsc, oneshot};
use futures::stream;
use futures_bounded::{FuturesMap, FuturesSet, PushError, StreamMap};
use futures_util::future::BoxFuture;
use futures_util::stream::FuturesUnordered;
use futures_util::{FutureExt, StreamExt};
use hickory_resolver::config::{NameServerConfig, Protocol, ResolverConfig};
use hickory_resolver::error::{ResolveError, ResolveResult};
use hickory_resolver::lookup::Lookup;
use hickory_resolver::TokioAsyncResolver;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use rand_core::OsRng;
use secrecy::Secret;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet, VecDeque};
use std::io;
use std::net::IpAddr;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::time::Instant;
use webrtc::data::data_channel::DataChannel;
use webrtc::data_channel::data_channel_init::RTCDataChannelInit;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;

impl<CB> Tunnel<CB, State>
where
    CB: Callbacks + 'static,
{
    /// Adds a the given resource to the tunnel.
    ///
    /// Once added, when a packet for the resource is intercepted a new data channel will be created
    /// and packets will be wrapped with wireguard and sent through it.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn add_resource(
        &self,
        resource_description: ResourceDescription,
    ) -> connlib_shared::Result<()> {
        let mut any_valid_route = false;
        {
            for ip in resource_description.ips() {
                if let Err(e) = self.add_route(ip).await {
                    tracing::warn!(route = %ip, error = ?e, "add_route");
                    let _ = self.callbacks().on_error(&e);
                } else {
                    any_valid_route = true;
                }
            }
        }
        if !any_valid_route {
            return Err(Error::InvalidResource);
        }

        let resource_list = {
            let mut role_state = self.role_state.lock();
            role_state.resources.insert(resource_description);
            role_state.resources.resource_list()
        };

        self.callbacks.on_update_resources(resource_list)?;
        Ok(())
    }

    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_interface(&self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        let device = Arc::new(create_iface(config, self.callbacks()).await?);

        self.device.store(Some(device.clone()));
        self.no_device_waker.wake();

        self.add_route(DNS_SENTINEL.into()).await?;
        self.role_state.lock().resolver =
            create_resolver(config.upstream_dns.clone(), self.callbacks());

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
    async fn add_route(&self, route: IpNetwork) -> connlib_shared::Result<()> {
        let maybe_new_device = self
            .device
            .load()
            .as_ref()
            .ok_or(Error::ControlProtocolError)?
            .add_route(route, self.callbacks())
            .await?;

        if let Some(new_device) = maybe_new_device {
            self.device.swap(Some(Arc::new(new_device)));
        }

        Ok(())
    }
}

/// [`Tunnel`] state specific to clients.
pub struct State {
    active_candidate_receivers: StreamMap<GatewayId, RTCIceCandidateInit>,
    /// We split the receivers of ICE candidates into two phases because we only want to start sending them once we've received an SDP from the gateway.
    waiting_for_sdp_from_gatway: HashMap<GatewayId, mpsc::Receiver<RTCIceCandidateInit>>,

    // TODO: Make private
    pub awaiting_connection: HashMap<ResourceId, AwaitingConnectionDetails>,
    pub gateway_awaiting_connection: HashSet<GatewayId>,

    awaiting_connection_timers: StreamMap<ResourceId, Instant>,

    pub gateway_public_keys: HashMap<GatewayId, PublicKey>,
    resources_gateways: HashMap<ResourceId, GatewayId>,
    resources: ResourceTable<ResourceDescription>,
    dns_queries: FuturesSet<(Result<Lookup, ResolveError>, IpPacket<'static>)>,

    #[allow(clippy::type_complexity)]
    awaiting_data_channels: FuturesMap<
        (ResourceId, GatewayId),
        Result<(Arc<DataChannel>, StaticSecret), oneshot::Canceled>,
    >,
    #[allow(clippy::type_complexity)]
    connection_setup: FuturesMap<
        (ResourceId, GatewayId),
        Result<
            (
                Arc<RTCPeerConnection>,
                mpsc::Receiver<RTCIceCandidateInit>,
                SecretKey,
                RTCSessionDescription,
            ),
            ConnlibError,
        >,
    >,
    failed_connection_listeners:
        FuturesUnordered<BoxFuture<'static, Result<(ResourceId, GatewayId), oneshot::Canceled>>>,

    queued_events: VecDeque<Event>,

    resolver: Option<TokioAsyncResolver>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AwaitingConnectionDetails {
    total_attemps: usize,
    response_received: bool,
    gateways: HashSet<GatewayId>,
}

impl State {
    pub(crate) fn register_new_data_channel(
        &mut self,
        resource: ResourceId,
        gateway: GatewayId,
        key: StaticSecret,
    ) -> oneshot::Sender<Arc<DataChannel>> {
        let (sender, receiver) = oneshot::channel();

        match self
            .awaiting_data_channels
            .try_push((resource, gateway), async move {
                let channel = receiver.await?;

                Ok((channel, key))
            }) {
            Ok(()) => {}
            Err(_) => {
                tracing::warn!("Failed to register new data channel");
            }
        }

        sender
    }
    /// Attempt to handle the given packet as a DNS packet.
    ///
    /// Returns `Ok` if the packet is in fact a DNS query with an optional response to send back.
    /// Returns `Err` if the packet is not a DNS query.
    pub(crate) fn handle_dns<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
    ) -> Result<Option<Packet<'a>>, MutableIpPacket<'a>> {
        match dns::parse(&self.resources, packet.as_immutable()) {
            Some(dns::ResolveStrategy::LocalResponse(pkt)) => Ok(Some(pkt)),
            Some(dns::ResolveStrategy::ForwardQuery(query)) => {
                self.add_dns_query(query);

                Ok(None)
            }
            None => Err(packet),
        }
    }

    pub(crate) fn new_peer_connection(
        &mut self,
        webrtc_api: Arc<webrtc::api::API>,
        relays: Vec<Relay>,
        resource_id: ResourceId,
        gateway_id: GatewayId,
    ) {
        let (failed_sender, failed_receiver) = oneshot::channel();
        let preshared_key = StaticSecret::random_from_rng(OsRng);

        let data_channel_sender =
            self.register_new_data_channel(resource_id, gateway_id, preshared_key.clone());

        // TODO: Error handling.
        let _ = self.connection_setup.try_push((resource_id, gateway_id), async move {
            let (peer_connection, ice_candidate_receiver) =
                new_peer_connection(&webrtc_api, relays).await?;

            peer_connection.on_peer_connection_state_change({
                let mut sender = Some(failed_sender); // We only need the sender once, hence use a `oneshot`.

                Box::new(move |state| {
                    let sender = sender.take();
                    Box::pin(async move {
                        tracing::trace!("peer_state");
                        if state == RTCPeerConnectionState::Failed {
                            if let Some(sender) = sender {
                                let _ = sender.send((resource_id, gateway_id));
                            }
                        }
                    })
                })
            });

            let data_channel = peer_connection
                .create_data_channel(
                    "data",
                    Some(RTCDataChannelInit {
                        ordered: Some(false),
                        max_retransmits: Some(0),
                        ..Default::default()
                    }),
                )
                .await?;
            let offer = peer_connection.create_offer(None).await?;
            peer_connection.set_local_description(offer.clone()).await?;

            let d = Arc::clone(&data_channel);

            data_channel.on_open(Box::new(move || {
                Box::pin(async move {
                    tracing::trace!("new_data_channel_opened");

                    let d = d.detach().await.expect(
                        "only fails if not opened or not enabled, both of which are always true for us",
                    );
                    let _ = data_channel_sender.send(d); // Ignore error if receiver is gone.
                })
            }));

            Ok((peer_connection, ice_candidate_receiver, Secret::new(Key(preshared_key.to_bytes())), offer))
        });

        self.failed_connection_listeners
            .push(failed_receiver.boxed());
    }

    pub(crate) fn request_connection(
        &mut self,
        resource: ResourceId,
        gateway: GatewayId,
        expected_attempts: usize,
        relays: Vec<Relay>,
        webrtc: Arc<webrtc::api::API>,
        connected_peers: &mut IpNetworkTable<ConnectedPeer<GatewayId>>,
    ) -> Result<(), ConnlibError> {
        if self.is_connected_to(resource, connected_peers) {
            return Err(Error::UnexpectedConnectionDetails);
        }

        let desc = self
            .resources
            .get_by_id(&resource)
            .ok_or(Error::UnknownResource)?;

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

        let Some(peer) = connected_peers.iter().find_map(|(_, p)| {
            (p.inner.conn_id == gateway).then_some(ConnectedPeer {
                inner: p.inner.clone(),
                channel: p.channel.clone(),
            })
        }) else {
            self.new_peer_connection(webrtc, relays, resource, gateway);

            return Ok(());
        };

        for ip in desc.ips() {
            peer.inner.add_allowed_ip(ip);
            connected_peers.insert(
                ip,
                ConnectedPeer {
                    inner: peer.inner.clone(),
                    channel: peer.channel.clone(),
                },
            );
        }
        self.awaiting_connection.remove(&resource);
        self.awaiting_connection_timers.remove(resource);

        self.queued_events
            .push_back(Event::ReuseConnection { gateway, resource });

        Ok(())
    }

    pub fn on_connection_failed(&mut self, resource: ResourceId) {
        self.awaiting_connection.remove(&resource);
        let Some(gateway) = self.resources_gateways.remove(&resource) else {
            return;
        };
        self.gateway_awaiting_connection.remove(&gateway);
        self.awaiting_connection_timers.remove(resource);
    }

    pub fn on_connection_intent(&mut self, destination: IpAddr) {
        if self.is_awaiting_connection_to(destination) {
            return;
        }

        tracing::trace!(resource_ip = %destination, "resource_connection_intent");

        let Some(resource) = self.get_resource_by_destination(destination) else {
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

        tracing::trace!(?gateways, "connected_gateways");

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
                gateways,
            },
        );
    }

    fn create_peer_config_for_new_connection(
        &mut self,
        resource: ResourceId,
        gateway: GatewayId,
        shared_key: StaticSecret,
    ) -> Result<PeerConfig, ConnlibError> {
        let Some(public_key) = self.gateway_public_keys.remove(&gateway) else {
            self.awaiting_connection.remove(&resource);
            self.gateway_awaiting_connection.remove(&gateway);

            return Err(Error::ControlProtocolError);
        };

        let desc = self
            .resources
            .get_by_id(&resource)
            .ok_or(Error::ControlProtocolError)?;

        Ok(PeerConfig {
            persistent_keepalive: None,
            public_key,
            ips: desc.ips(),
            preshared_key: SecretKey::new(Key(shared_key.to_bytes())),
        })
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.resources_gateways.get(resource).copied()
    }

    pub fn add_waiting_ice_receiver(
        &mut self,
        id: GatewayId,
        receiver: mpsc::Receiver<RTCIceCandidateInit>,
    ) {
        self.waiting_for_sdp_from_gatway.insert(id, receiver);
    }

    pub fn activate_ice_candidate_receiver(&mut self, id: GatewayId, key: PublicKey) {
        let Some(receiver) = self.waiting_for_sdp_from_gatway.remove(&id) else {
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

    fn is_awaiting_connection_to(&self, destination: IpAddr) -> bool {
        let Some(resource) = self.get_resource_by_destination(destination) else {
            return false;
        };

        self.awaiting_connection.contains_key(&resource.id())
    }

    fn is_connected_to(
        &self,
        resource: ResourceId,
        connected_peers: &IpNetworkTable<ConnectedPeer<GatewayId>>,
    ) -> bool {
        let Some(resource) = self.resources.get_by_id(&resource) else {
            return false;
        };

        resource
            .ips()
            .iter()
            .any(|ip| connected_peers.exact_match(*ip).is_some())
    }

    fn get_resource_by_destination(&self, destination: IpAddr) -> Option<&ResourceDescription> {
        match destination {
            IpAddr::V4(ipv4) => self.resources.get_by_ip(ipv4),
            IpAddr::V6(ipv6) => self.resources.get_by_ip(ipv6),
        }
    }

    pub fn add_dns_query(&mut self, query: DnsQuery) {
        let query = query.into_owned();

        let Some(resolver) = self.resolver.clone() else {
            tracing::warn!("No DNS resolver configured");
            return;
        };

        let result = self.dns_queries.try_push(async move {
            let result = resolver.lookup(query.name, query.record_type).await;

            (result, query.query)
        });

        if result.is_err() {
            tracing::warn!("Too many DNS queries, dropping new ones");
        }
    }

    pub(crate) fn poll_next_event(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Either<Event, InternalEvent>> {
        loop {
            if let Some(event) = self.queued_events.pop_front() {
                return Poll::Ready(Either::Left(event));
            }

            match self.awaiting_data_channels.poll_unpin(cx) {
                Poll::Ready(((resource_id, gateway_id), Ok(Ok((channel, p_key))))) => {
                    let peer_config = match self.create_peer_config_for_new_connection(
                        resource_id,
                        gateway_id,
                        p_key,
                    ) {
                        Ok(c) => c,
                        Err(e) => {
                            return Poll::Ready(Either::Right(InternalEvent::ConnectionFailed(
                                gateway_id, e,
                            )))
                        }
                    };

                    self.gateway_awaiting_connection.remove(&gateway_id);
                    self.awaiting_connection.remove(&resource_id);

                    return Poll::Ready(Either::Right(InternalEvent::NewPeer {
                        config: peer_config,
                        id: gateway_id,
                        channel,
                    }));
                }
                Poll::Ready(_) => {
                    todo!()
                }
                Poll::Pending => {}
            }

            match self.active_candidate_receivers.poll_next_unpin(cx) {
                Poll::Ready((conn_id, Some(Ok(c)))) => {
                    return Poll::Ready(Either::Left(Event::SignalIceCandidate {
                        conn_id,
                        candidate: c,
                    }))
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

                    return Poll::Ready(Either::Left(Event::ConnectionIntent {
                        resource: self
                            .resources
                            .get_by_id(&resource)
                            .expect("inconsistent internal state")
                            .clone(),
                        connected_gateway_ids: entry.get().gateways.clone(),
                        reference,
                    }));
                }

                Poll::Ready((id, Some(Err(e)))) => {
                    tracing::warn!(resource_id = %id, "Connection establishment timeout: {e}")
                }
                Poll::Ready((_, None)) => continue,
                Poll::Pending => {}
            }

            match self.failed_connection_listeners.poll_next_unpin(cx) {
                Poll::Ready(Some(Ok((resource, gateway)))) => {
                    self.on_connection_failed(resource);
                    return Poll::Ready(Either::Right(InternalEvent::ConnectionFailed(
                        gateway,
                        ConnlibError::Other("Failed to set up connection"),
                    )));
                }
                Poll::Ready(Some(Err(_))) => {
                    // Connection got de-allocated before it failed, nothing to do ...
                    continue;
                }
                Poll::Ready(None) | Poll::Pending => {}
            }

            match self.connection_setup.poll_unpin(cx) {
                Poll::Ready(((resource, gateway), Ok(Ok((conn, ice_receiver, key, desc))))) => {
                    self.add_waiting_ice_receiver(gateway, ice_receiver);
                    return Poll::Ready(Either::Right(InternalEvent::ConnectionConfigured {
                        gateway,
                        resource,
                        key,
                        desc,
                        conn,
                    }));
                }
                Poll::Ready(((_, gateway), Ok(Err(e)))) => {
                    return Poll::Ready(Either::Right(InternalEvent::ConnectionFailed(gateway, e)));
                }
                Poll::Ready(((_, gateway), Err(_))) => {
                    return Poll::Ready(Either::Right(InternalEvent::ConnectionFailed(
                        gateway,
                        ConnlibError::Io(io::ErrorKind::TimedOut.into()),
                    )));
                }
                Poll::Pending => {}
            }

            match self.dns_queries.poll_unpin(cx) {
                Poll::Ready(Ok((result, query))) => {
                    return Poll::Ready(Either::Right(InternalEvent::DnsLookupComplete {
                        result,
                        query,
                    }))
                }
                Poll::Ready(Err(e)) => {
                    tracing::warn!("DNS lookup timed out: {e}");
                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}

impl Default for State {
    fn default() -> Self {
        Self {
            active_candidate_receivers: StreamMap::new(
                Duration::from_secs(ICE_GATHERING_TIMEOUT_SECONDS),
                MAX_CONCURRENT_ICE_GATHERING,
            ),
            waiting_for_sdp_from_gatway: Default::default(),
            awaiting_connection: Default::default(),
            gateway_awaiting_connection: Default::default(),
            awaiting_connection_timers: StreamMap::new(Duration::from_secs(60), 100),
            gateway_public_keys: Default::default(),
            resources_gateways: Default::default(),
            resources: Default::default(),
            dns_queries: FuturesSet::new(Duration::from_secs(60), DNS_QUERIES_QUEUE_SIZE),
            awaiting_data_channels: FuturesMap::new(Duration::from_secs(60), 100),
            connection_setup: FuturesMap::new(Duration::from_secs(60), 100),
            failed_connection_listeners: Default::default(),
            queued_events: Default::default(),
            resolver: None,
        }
    }
}

impl RoleState for State {
    type Id = GatewayId;
}

#[allow(clippy::large_enum_variant)]
pub(crate) enum InternalEvent {
    ConnectionFailed(GatewayId, ConnlibError),
    ConnectionConfigured {
        gateway: GatewayId,
        resource: ResourceId,
        key: SecretKey,
        desc: RTCSessionDescription,
        conn: Arc<RTCPeerConnection>,
    },
    NewPeer {
        config: PeerConfig,
        id: GatewayId,
        channel: Arc<DataChannel>,
    },
    DnsLookupComplete {
        // TODO: Technically we only need the IP header.
        query: IpPacket<'static>,
        result: ResolveResult<Lookup>,
    },
}

#[allow(clippy::large_enum_variant)]
pub enum Event {
    SignalIceCandidate {
        conn_id: GatewayId,
        candidate: RTCIceCandidateInit,
    },
    ConnectionIntent {
        resource: ResourceDescription,
        connected_gateway_ids: HashSet<GatewayId>,
        reference: usize,
    },
    NewConnection {
        gateway: GatewayId,
        resource: ResourceId,
        key: SecretKey,
        desc: RTCSessionDescription,
    },
    ReuseConnection {
        gateway: GatewayId,
        resource: ResourceId,
    },
}

fn create_resolver(
    upstream_dns: Vec<DnsServer>,
    callbacks: &impl Callbacks,
) -> Option<TokioAsyncResolver> {
    const DNS_PORT: u16 = 53;

    let dns_servers = if upstream_dns.is_empty() {
        let Ok(Some(dns_servers)) = callbacks.get_system_default_resolvers() else {
            return None;
        };
        if dns_servers.is_empty() {
            return None;
        }
        dns_servers
            .into_iter()
            .map(|ip| {
                DnsServer::IpPort(IpDnsServer {
                    address: (ip, DNS_PORT).into(),
                })
            })
            .collect()
    } else {
        upstream_dns
    };

    let mut resolver_config = ResolverConfig::new();
    for srv in dns_servers.iter() {
        let name_server = match srv {
            DnsServer::IpPort(srv) => NameServerConfig::new(srv.address, Protocol::Udp),
        };

        resolver_config.add_name_server(name_server);
    }

    Some(TokioAsyncResolver::tokio(
        resolver_config,
        Default::default(),
    ))
}
