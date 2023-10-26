use crate::device_channel::create_iface;
use crate::{
    Device, Event, RoleState, Tunnel, ICE_GATHERING_TIMEOUT_SECONDS, MAX_CONCURRENT_ICE_GATHERING,
    MAX_UDP_SIZE,
};
use connlib_shared::error::ConnlibError;
use connlib_shared::messages::{ClientId, Interface as InterfaceConfig};
use connlib_shared::Callbacks;
use futures::channel::mpsc::Receiver;
use futures_bounded::{PushError, StreamMap};
use futures_util::SinkExt;
use std::net::IpAddr;
use std::sync::Arc;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

impl<CB> Tunnel<CB, GatewayState>
where
    CB: Callbacks + 'static,
{
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_interface(
        self: &Arc<Self>,
        config: &InterfaceConfig,
    ) -> connlib_shared::Result<()> {
        let device = create_iface(config, self.callbacks()).await?;

        *self.device.write().await = Some(device.clone());
        *self.iface_handler_abort.lock() =
            Some(tokio::spawn(device_handler(Arc::clone(self), device)).abort_handle());

        tracing::debug!("background_loop_started");

        Ok(())
    }

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&self, id: ClientId) {
        self.peer_connections.lock().remove(&id);
    }
}

/// Reads IP packets from the [`Device`] and handles them accordingly.
async fn device_handler<CB>(
    tunnel: Arc<Tunnel<CB, GatewayState>>,
    mut device: Device,
) -> Result<(), ConnlibError>
where
    CB: Callbacks + 'static,
{
    let mut buf = [0u8; MAX_UDP_SIZE];
    loop {
        let Some(packet) = device.read().await? else {
            // Reading a bad IP packet or otherwise from the device seems bad. Should we restart the tunnel or something?
            return Ok(());
        };

        let dest = packet.destination();

        let (result, channel, peer_id) = {
            let mut peers = tunnel.peers.write();

            let Some((client, peer)) = tunnel
                .peers_by_ip
                .read()
                .longest_match(dest)
                .and_then(|(_, id)| Some((*id, peers.get_mut(id)?)))
            else {
                continue;
            };

            let result = peer.inner.encapsulate(packet, dest, &mut buf);
            let channel = peer.channel.clone();

            (result, channel, client)
        };

        let error = match result {
            Ok(None) => continue,
            Ok(Some(b)) => match channel.write(&b).await {
                Ok(_) => continue,
                Err(e) => ConnlibError::IceDataError(e),
            },
            Err(e) => e,
        };

        on_error(&tunnel, dest, error, peer_id).await
    }
}

async fn on_error<CB>(
    tunnel: &Tunnel<CB, GatewayState>,
    dest: IpAddr,
    e: ConnlibError,
    peer_id: ClientId,
) where
    CB: Callbacks + 'static,
{
    tracing::error!(resource_address = %dest, err = ?e, "failed to handle packet {e:#}");

    if e.is_fatal_connection_error() {
        let _ = tunnel.stop_peer_command_sender.clone().send(peer_id).await;
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct GatewayState {
    candidate_receivers: StreamMap<ClientId, RTCIceCandidateInit>,
}

impl GatewayState {
    pub fn add_new_ice_receiver(&mut self, id: ClientId, receiver: Receiver<RTCIceCandidateInit>) {
        match self.candidate_receivers.try_push(id, receiver) {
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

impl Default for GatewayState {
    fn default() -> Self {
        Self {
            candidate_receivers: StreamMap::new(
                Duration::from_secs(ICE_GATHERING_TIMEOUT_SECONDS),
                MAX_CONCURRENT_ICE_GATHERING,
            ),
        }
    }
}

impl RoleState for GatewayState {
    type Id = ClientId;

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>> {
        loop {
            match ready!(self.candidate_receivers.poll_next_unpin(cx)) {
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
