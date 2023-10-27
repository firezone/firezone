use crate::bounded_queue::BoundedQueue;
use crate::device_channel::create_iface;
use crate::ip_packet::{IpPacket, MutableIpPacket};
use crate::peer::WriteTo;
use crate::resource_table::ResourceTable;
use crate::{
    dns, peer_by_ip, tokio_util, ConnectedPeer, Device, DnsQuery, Event, PeerConfig, RoleState,
    Tunnel, DNS_QUERIES_QUEUE_SIZE, ICE_GATHERING_TIMEOUT_SECONDS, MAX_CONCURRENT_ICE_GATHERING,
    MAX_UDP_SIZE,
};
use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::{
    GatewayId, Interface as InterfaceConfig, Key, ResourceDescription, ResourceId, ReuseConnection,
    SecretKey,
};
use connlib_shared::{Callbacks, DNS_SENTINEL};
use futures::channel::mpsc::Receiver;
use futures::stream;
use futures_bounded::{PushError, StreamMap};
use futures_util::SinkExt;
use hickory_resolver::lookup::Lookup;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::time::Instant;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

impl<CB> Tunnel<CB, ClientState>
where
    CB: Callbacks + 'static,
{
    /// Adds a the given resource to the tunnel.
    ///
    /// Once added, when a packet for the resource is intercepted a new data channel will be created
    /// and packets will be wrapped with wireguard and sent through it.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn add_resource(
        self: &Arc<Self>,
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

    /// Writes the response to a DNS lookup
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn write_dns_lookup_response(
        self: &Arc<Self>,
        response: hickory_resolver::error::ResolveResult<Lookup>,
        query: IpPacket<'static>,
    ) -> connlib_shared::Result<()> {
        if let Some(pkt) = dns::build_response_from_resolve_result(query, response)? {
            let Some(ref device) = *self.device.read().await else {
                return Ok(());
            };

            device.io.write(pkt)?;
        }

        Ok(())
    }

    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_interface(
        self: &Arc<Self>,
        config: &InterfaceConfig,
    ) -> connlib_shared::Result<()> {
        let device = create_iface(config, self.callbacks()).await?;

        *self.device.write().await = Some(device.clone());
        *self.iface_handler_abort.lock() = Some(tokio_util::spawn_log(
            &self.callbacks,
            device_handler(Arc::clone(self), device),
        ));

        self.add_route(DNS_SENTINEL.into()).await?;

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
    async fn add_route(self: &Arc<Self>, route: IpNetwork) -> connlib_shared::Result<()> {
        let mut device = self.device.write().await;

        if let Some(new_device) = device
            .as_ref()
            .ok_or(Error::ControlProtocolError)?
            .config
            .add_route(route, self.callbacks())
            .await?
        {
            *device = Some(new_device.clone());
            *self.iface_handler_abort.lock() = Some(tokio_util::spawn_log(
                &self.callbacks,
                device_handler(Arc::clone(self), new_device),
            ));
        }

        Ok(())
    }
}

/// Reads IP packets from the [`Device`] and handles them accordingly.
async fn device_handler<CB>(
    tunnel: Arc<Tunnel<CB, ClientState>>,
    mut device: Device,
) -> Result<(), ConnlibError>
where
    CB: Callbacks + 'static,
{
    let device_writer = device.io.clone();
    let mut buf = [0u8; MAX_UDP_SIZE];
    loop {
        let Some(packet) = device.read().await? else {
            return Ok(());
        };

        let dest = packet.destination();
        let (peer_index, peer_conn_id, peer_channel, maybe_write_to) = {
            let peers_by_ip = tunnel.peers_by_ip.read();
            let peer = peer_by_ip(&peers_by_ip, dest);

            let result = tunnel
                .role_state
                .lock()
                .handle_new_packet(packet, peer, &mut buf);

            let maybe_write_to = match result {
                Ok(None) => continue,
                Ok(Some(write_to)) => Ok(write_to),
                Err(e) => Err(e),
            };

            let peer = peer.expect("must have peer if we should write bytes");

            (
                peer.inner.index,
                peer.inner.conn_id,
                peer.channel.clone(),
                maybe_write_to,
            )
        };

        let error = match maybe_write_to {
            Ok(WriteTo::Network(bytes)) => match peer_channel.write(&bytes).await {
                Ok(_) => continue,
                Err(e) => ConnlibError::IceDataError(e),
            },
            Ok(WriteTo::Resource(packet)) => match device_writer.write(packet) {
                Ok(_) => continue,
                Err(e) => ConnlibError::Io(e),
            },
            Err(e) => e,
        };

        tracing::error!(resource_address = %dest, err = ?error, "failed to handle packet {error:#}");

        let _ = tunnel.callbacks.on_error(&error);

        if error.is_fatal_connection_error() {
            let _ = tunnel
                .stop_peer_command_sender
                .clone()
                .send((peer_index, peer_conn_id))
                .await;
        }
    }
}

/// [`Tunnel`] state specific to clients.
pub struct ClientState {
    active_candidate_receivers: StreamMap<GatewayId, RTCIceCandidateInit>,
    /// We split the receivers of ICE candidates into two phases because we only want to start sending them once we've received an SDP from the gateway.
    waiting_for_sdp_from_gatway: HashMap<GatewayId, Receiver<RTCIceCandidateInit>>,

    // TODO: Make private
    pub awaiting_connection: HashMap<ResourceId, AwaitingConnectionDetails>,
    pub gateway_awaiting_connection: HashSet<GatewayId>,

    awaiting_connection_timers: StreamMap<ResourceId, Instant>,

    pub gateway_public_keys: HashMap<GatewayId, PublicKey>,
    resources_gateways: HashMap<ResourceId, GatewayId>,
    resources: ResourceTable<ResourceDescription>,
    dns_queries: BoundedQueue<DnsQuery<'static>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AwaitingConnectionDetails {
    total_attemps: usize,
    response_received: bool,
    gateways: HashSet<GatewayId>,
}

impl ClientState {
    pub(crate) fn handle_new_packet<'b>(
        &mut self,
        packet: MutableIpPacket,
        peer: Option<&ConnectedPeer<GatewayId>>,
        buf: &'b mut [u8],
    ) -> Result<Option<WriteTo<'b>>, ConnlibError> {
        match dns::parse(&self.resources, packet.as_immutable()) {
            Some(dns::ResolveStrategy::LocalResponse(pkt)) => {
                return Ok(Some(WriteTo::Resource(pkt)))
            }
            Some(dns::ResolveStrategy::ForwardQuery(query)) => {
                self.add_pending_dns_query(query);
                return Ok(None);
            }
            None => {}
        }

        let dest = packet.destination();

        let Some(peer) = peer else {
            self.on_connection_intent(dest);
            return Ok(None);
        };

        let Some(bytes) = peer.inner.encapsulate(packet, dest, buf)? else {
            return Ok(None);
        };

        Ok(Some(WriteTo::Network(bytes)))
    }

    pub(crate) fn attempt_to_reuse_connection(
        &mut self,
        resource: ResourceId,
        gateway: GatewayId,
        expected_attempts: usize,
        connected_peers: &mut IpNetworkTable<ConnectedPeer<GatewayId>>,
    ) -> Result<Option<ReuseConnection>, ConnlibError> {
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
            return Ok(None);
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

        Ok(Some(ReuseConnection {
            resource_id: resource,
            gateway_id: gateway,
        }))
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

    pub fn create_peer_config_for_new_connection(
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
        receiver: Receiver<RTCIceCandidateInit>,
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

    pub fn add_pending_dns_query(&mut self, query: DnsQuery) {
        if self.dns_queries.push_back(query.into_owned()).is_err() {
            tracing::warn!("Too many DNS queries, dropping new ones");
        }
    }
}

impl Default for ClientState {
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
            dns_queries: BoundedQueue::with_capacity(DNS_QUERIES_QUEUE_SIZE),
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
                            .resources
                            .get_by_id(&resource)
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

            return self.dns_queries.poll(cx).map(Event::DnsQuery);
        }
    }
}
