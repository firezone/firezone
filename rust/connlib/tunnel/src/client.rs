use crate::device_channel::{create_iface, DeviceIo};
use crate::ip_packet::IpPacket;
use crate::peer::Peer;
use crate::resource_table::ResourceTable;
use crate::{
    dns, tokio_util, Device, Event, RoleState, Tunnel, ICE_GATHERING_TIMEOUT_SECONDS,
    MAX_CONCURRENT_ICE_GATHERING, MAX_UDP_SIZE,
};
use boringtun::x25519::PublicKey;
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::{
    GatewayId, Interface as InterfaceConfig, ResourceDescription, ResourceId, ReuseConnection,
};
use connlib_shared::{Callbacks, DNS_SENTINEL};
use futures::channel::mpsc::Receiver;
use futures::stream;
use futures_bounded::{PushError, StreamMap};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::io;
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

    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_interface(
        self: &Arc<Self>,
        config: &InterfaceConfig,
    ) -> connlib_shared::Result<()> {
        let device = create_iface(config, self.callbacks()).await?;
        *self.device.write().await = Some(device.clone());

        self.start_timers().await?;
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
        self.peer_connections.lock().remove(&id.into());
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

    #[inline(always)]
    fn connection_intent(self: &Arc<Self>, packet: IpPacket<'_>) {
        // We can buffer requests here but will drop them for now and let the upper layer reliability protocol handle this

        // We have awaiting connection to prevent a race condition where
        // create_peer_connection hasn't added the thing to peer_connections
        // and we are finding another packet to the same address (otherwise we would just use peer_connections here)
        let mut role_state = self.role_state.lock();

        if role_state.is_awaiting_connection_to(packet.destination()) {
            return;
        }

        tracing::trace!(resource_ip = %packet.destination(), "resource_connection_intent");

        role_state.insert_new_awaiting_connection(packet.destination());
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

        if let Some(dns_packet) =
            dns::parse(&tunnel.role_state.lock().resources, packet.as_immutable())
        {
            if let Err(e) = send_dns_packet(&device_writer, dns_packet) {
                tracing::error!(err = %e, "failed to send DNS packet");
                let _ = tunnel.callbacks.on_error(&e.into());
            }

            continue;
        }

        let dest = packet.destination();

        let Some(peer) = tunnel.peer_by_ip(dest) else {
            tunnel.connection_intent(packet.as_immutable());
            continue;
        };

        if let Err(e) = tunnel
            .encapsulate_and_send_to_peer(packet, peer, &dest, &mut buf)
            .await
        {
            let _ = tunnel.callbacks.on_error(&e);
            tracing::error!(err = ?e, "failed to handle packet {e:#}")
        }
    }
}

fn send_dns_packet(device_writer: &DeviceIo, packet: dns::Packet) -> io::Result<()> {
    match packet {
        dns::Packet::Ipv4(r) => device_writer.write4(&r[..])?,
        dns::Packet::Ipv6(r) => device_writer.write6(&r[..])?,
    };

    Ok(())
}

/// [`Tunnel`] state specific to clients.
pub struct ClientState {
    active_candidate_receivers: StreamMap<GatewayId, RTCIceCandidateInit>,
    /// We split the receivers of ICE candidates into two phases because we only want to start sending them once we've received an SDP from the gateway.
    waiting_for_sdp_from_gatway: HashMap<GatewayId, Receiver<RTCIceCandidateInit>>,

    // TODO: Make private
    pub awaiting_connection: HashMap<ResourceId, (AwaitingConnectionDetails, Vec<GatewayId>)>,
    pub gateway_awaiting_connection: HashMap<GatewayId, Vec<IpNetwork>>,

    awaiting_connection_timers: StreamMap<ResourceId, Instant>,

    pub gateway_public_keys: HashMap<GatewayId, PublicKey>,
    resources_gateways: HashMap<ResourceId, GatewayId>,
    resources: ResourceTable<ResourceDescription>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AwaitingConnectionDetails {
    pub total_attemps: usize,
    pub response_received: bool,
}

impl ClientState {
    pub(crate) fn on_new_connection(
        &mut self,
        resource: ResourceId,
        gateway: GatewayId,
        expected_attempts: usize,
        connected_peers: &IpNetworkTable<Arc<Peer>>,
    ) -> Result<(ResourceDescription, Option<ReuseConnection>), ConnlibError> {
        if self.is_connected_to(resource, connected_peers) {
            return Err(Error::UnexpectedConnectionDetails);
        }

        let desc = self
            .resources
            .get_by_id(&resource)
            .ok_or(Error::UnknownResource)?;

        let (details, _) = self
            .awaiting_connection
            .get_mut(&resource)
            .ok_or(Error::UnexpectedConnectionDetails)?;

        details.response_received = true;

        if details.total_attemps != expected_attempts {
            return Err(Error::UnexpectedConnectionDetails);
        }

        self.resources_gateways.insert(resource, gateway);

        match self.gateway_awaiting_connection.entry(gateway) {
            Entry::Occupied(mut occupied) => {
                occupied.get_mut().extend(desc.ips());
                Ok((
                    desc.clone(),
                    Some(ReuseConnection {
                        resource_id: resource,
                        gateway_id: gateway,
                    }),
                ))
            }
            Entry::Vacant(vacant) => {
                vacant.insert(vec![]);
                Ok((desc.clone(), None))
            }
        }
    }

    pub fn on_connection_failed(&mut self, resource: ResourceId) {
        self.awaiting_connection.remove(&resource);
        let Some(gateway) = self.resources_gateways.remove(&resource) else {
            return;
        };
        self.gateway_awaiting_connection.remove(&gateway);
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.resources_gateways.get(resource).copied()
    }

    pub fn is_awaiting_connection_to(&self, destination: IpAddr) -> bool {
        let Some(resource) = self.get_resource_by_destination(destination) else {
            return false;
        };

        self.awaiting_connection.contains_key(&resource.id())
    }

    pub fn insert_new_awaiting_connection(&mut self, destination: IpAddr) {
        let Some(resource) = self.get_resource_by_destination(destination) else {
            return;
        };

        const MAX_SIGNAL_CONNECTION_DELAY: Duration = Duration::from_secs(2);

        let resource_id = resource.id();

        let connected_gateway_ids = self
            .gateway_awaiting_connection
            .clone()
            .into_keys()
            .chain(self.resources_gateways.values().cloned())
            .collect();

        tracing::trace!(
            gateways = ?connected_gateway_ids,
            "connected_gateways"
        );

        self.awaiting_connection
            .insert(resource_id, (Default::default(), connected_gateway_ids));

        // TODO: Handle error
        let _ = self.awaiting_connection_timers.try_push(
            resource_id,
            stream::poll_fn({
                let mut interval = tokio::time::interval(MAX_SIGNAL_CONNECTION_DELAY);
                move |cx| interval.poll_tick(cx).map(Some)
            }),
        );
    }

    pub fn remove_awaiting_connection(&mut self, resource: ResourceId) {
        self.awaiting_connection.remove(&resource);
        self.awaiting_connection_timers.remove(resource);
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

    fn is_connected_to(
        &self,
        resource: ResourceId,
        connected_peers: &IpNetworkTable<Arc<Peer>>,
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
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}")
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

                    if entry.get().0.response_received {
                        self.awaiting_connection_timers.remove(resource);

                        // entry.remove(); Maybe?

                        continue;
                    }

                    entry.get_mut().0.total_attemps += 1;

                    let reference = entry.get_mut().0.total_attemps;

                    return Poll::Ready(Event::ConnectionIntent {
                        resource: self
                            .resources
                            .get_by_id(&resource)
                            .expect("inconsistent internal state")
                            .clone(),
                        connected_gateway_ids: entry.get().1.clone(),
                        reference,
                    });
                }

                Poll::Ready((id, Some(Err(e)))) => {
                    tracing::warn!(resource_id = %id, "Connection establishment timeout: {e}")
                }
                Poll::Ready((_, None)) => continue,
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}
