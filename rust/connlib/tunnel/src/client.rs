use crate::device_channel::{create_iface, DeviceIo};
use crate::ip_packet::IpPacket;
use crate::{
    dns, tokio_util, ConnId, ControlSignal, Device, Event, RoleState, Tunnel,
    ICE_GATHERING_TIMEOUT_SECONDS, MAX_CONCURRENT_ICE_GATHERING, MAX_UDP_SIZE,
};
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::{
    GatewayId, Interface as InterfaceConfig, ResourceDescription, ResourceId,
};
use connlib_shared::{Callbacks, DNS_SENTINEL};
use futures::channel::mpsc::Receiver;
use futures_bounded::{PushError, StreamMap};
use ip_network::IpNetwork;
use std::collections::HashMap;
use std::io;
use std::sync::Arc;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

impl<C, CB> Tunnel<C, CB, ClientState>
where
    C: ControlSignal + Send + Sync + 'static,
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
            let mut resources = self.resources.write();
            resources.insert(resource_description);
            resources.resource_list()
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
    pub fn cleanup_connection(&self, id: ConnId) {
        if let ConnId::Resource(r) = id {
            self.role_state.lock().awaiting_connection.remove(&r);
        }
        self.peer_connections.lock().remove(&id);
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
        const MAX_SIGNAL_CONNECTION_DELAY: Duration = Duration::from_secs(2);

        // We can buffer requests here but will drop them for now and let the upper layer reliability protocol handle this

        let Some(resource) = self.get_resource(packet.destination()) else {
            return;
        };

        // We have awaiting connection to prevent a race condition where
        // create_peer_connection hasn't added the thing to peer_connections
        // and we are finding another packet to the same address (otherwise we would just use peer_connections here)
        let mut role_state = self.role_state.lock();

        if role_state.awaiting_connection.get(&resource.id()).is_some() {
            return;
        }

        tracing::trace!(resource_ip = %packet.destination(), "resource_connection_intent");

        role_state
            .awaiting_connection
            .insert(resource.id(), Default::default());
        let dev = Arc::clone(self);

        let mut connected_gateway_ids: Vec<_> = role_state
            .gateway_awaiting_connection
            .clone()
            .into_keys()
            .collect();
        connected_gateway_ids.extend(dev.resources_gateways.lock().values().collect::<Vec<_>>());
        tracing::trace!(
            gateways = ?connected_gateway_ids,
            "connected_gateways"
        );
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(MAX_SIGNAL_CONNECTION_DELAY);
            loop {
                interval.tick().await;
                let reference = {
                    let mut role_state = dev.role_state.lock();

                    let Some(awaiting_connection) =
                        role_state.awaiting_connection.get_mut(&resource.id())
                    else {
                        break;
                    };
                    if awaiting_connection.response_received {
                        break;
                    }
                    awaiting_connection.total_attemps += 1;
                    awaiting_connection.total_attemps
                };
                if let Err(e) = dev
                    .control_signaler
                    .signal_connection_to(&resource, &connected_gateway_ids, reference)
                    .await
                {
                    // Not a deadlock because this is a different task
                    dev.role_state
                        .lock()
                        .awaiting_connection
                        .remove(&resource.id());
                    tracing::error!(error = ?e, "start_resource_connection");
                    let _ = dev.callbacks.on_error(&e);
                }
            }
        });
    }
}

/// Reads IP packets from the [`Device`] and handles them accordingly.
async fn device_handler<C, CB>(
    tunnel: Arc<Tunnel<C, CB, ClientState>>,
    mut device: Device,
) -> Result<(), ConnlibError>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    let device_writer = device.io.clone();
    let mut buf = [0u8; MAX_UDP_SIZE];
    loop {
        let Some(packet) = device.read().await? else {
            return Ok(());
        };

        if let Some(dns_packet) = dns::parse(&tunnel.resources.read(), packet.as_immutable()) {
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

    pub awaiting_connection: HashMap<ResourceId, AwaitingConnectionDetails>,
    pub gateway_awaiting_connection: HashMap<GatewayId, Vec<IpNetwork>>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AwaitingConnectionDetails {
    pub total_attemps: usize,
    pub response_received: bool,
}

impl ClientState {
    pub fn add_waiting_ice_receiver(
        &mut self,
        id: GatewayId,
        receiver: Receiver<RTCIceCandidateInit>,
    ) {
        self.waiting_for_sdp_from_gatway.insert(id, receiver);
    }

    pub fn activate_ice_candidate_receiver(&mut self, id: GatewayId) {
        let Some(receiver) = self.waiting_for_sdp_from_gatway.remove(&id) else {
            return;
        };

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
        }
    }
}

impl RoleState for ClientState {
    type Id = GatewayId;

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>> {
        loop {
            match ready!(self.active_candidate_receivers.poll_next_unpin(cx)) {
                (conn_id, Some(Ok(c))) => {
                    return Poll::Ready(Event::SignalIceCandidate {
                        conn_id,
                        candidate: c,
                    })
                }
                (id, Some(Err(e))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}")
                }
                (_, None) => {}
            }
        }
    }
}
