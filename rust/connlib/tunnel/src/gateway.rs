use crate::device_channel::Device;
use crate::peer::PacketTransformGateway;
use crate::{
    ConnectedPeer, Event, RoleState, Tunnel, ICE_GATHERING_TIMEOUT_SECONDS,
    MAX_CONCURRENT_ICE_GATHERING,
};
use connlib_shared::messages::{ClientId, Interface as InterfaceConfig};
use connlib_shared::Callbacks;
use futures::channel::mpsc::Receiver;
use futures_bounded::{PushError, StreamMap};
use ip_network_table::IpNetworkTable;
use itertools::Itertools;
use std::collections::VecDeque;
use std::sync::Arc;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use webrtc::ice_transport::ice_candidate::RTCIceCandidate;

const PEERS_IPV4: &str = "100.64.0.0/11";
const PEERS_IPV6: &str = "fd00:2021:1111::/107";

impl<CB> Tunnel<CB, GatewayState>
where
    CB: Callbacks + 'static,
{
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        // Note: the dns fallback strategy is irrelevant for gateways
        let device = Arc::new(Device::new(config, vec![], self.callbacks())?);

        let result_v4 = device.add_route(PEERS_IPV4.parse().unwrap(), self.callbacks());
        let result_v6 = device.add_route(PEERS_IPV6.parse().unwrap(), self.callbacks());
        result_v4.or(result_v6)?;

        self.device.store(Some(device.clone()));
        self.no_device_waker.wake();

        tracing::debug!("background_loop_started");

        Ok(())
    }

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&self, id: ClientId) {
        self.peer_connections.lock().remove(&id);
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct GatewayState {
    pub candidate_receivers: StreamMap<ClientId, RTCIceCandidate>,
    #[allow(clippy::type_complexity)]
    pub peers_by_ip: IpNetworkTable<ConnectedPeer<ClientId, PacketTransformGateway>>,
}

impl GatewayState {
    pub fn add_new_ice_receiver(&mut self, id: ClientId, receiver: Receiver<RTCIceCandidate>) {
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
            peers_by_ip: IpNetworkTable::new(),
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
                    });
                }
                (id, Some(Err(e))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}")
                }
                (_, None) => {}
            }
        }
    }

    fn remove_peers(&mut self, conn_id: ClientId) {
        self.peers_by_ip.retain(|_, p| p.inner.conn_id != conn_id);
    }

    fn refresh_peers(&mut self) -> VecDeque<Self::Id> {
        let mut peers_to_stop = VecDeque::new();
        for (_, peer) in self.peers_by_ip.iter().unique_by(|(_, p)| p.inner.conn_id) {
            let conn_id = peer.inner.conn_id;

            peer.inner.transform.expire_resources();

            if peer.inner.transform.is_emptied() {
                tracing::trace!(%conn_id, "peer_expired");
                peers_to_stop.push_back(conn_id);

                continue;
            }

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
