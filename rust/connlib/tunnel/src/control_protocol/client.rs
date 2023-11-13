use std::sync::Arc;

use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::{
    messages::{GatewayId, Key, Relay, RequestConnection, ResourceId},
    Callbacks,
};
use rand_core::OsRng;
use secrecy::Secret;
use webrtc::{
    data_channel::data_channel_init::RTCDataChannelInit,
    peer_connection::{
        peer_connection_state::RTCPeerConnectionState,
        sdp::session_description::RTCSessionDescription, RTCPeerConnection,
    },
};

use crate::control_protocol::new_peer_connection;
use crate::{client, Error, Request, Result, Tunnel};

#[tracing::instrument(level = "trace", skip(tunnel))]
fn set_connection_state_update<CB>(
    tunnel: &Arc<Tunnel<CB, client::State>>,
    peer_connection: &Arc<RTCPeerConnection>,
    gateway_id: GatewayId,
    resource_id: ResourceId,
) where
    CB: Callbacks + 'static,
{
    let tunnel = Arc::clone(tunnel);
    peer_connection.on_peer_connection_state_change(Box::new(
        move |state: RTCPeerConnectionState| {
            let tunnel = Arc::clone(&tunnel);
            Box::pin(async move {
                tracing::trace!("peer_state");
                if state == RTCPeerConnectionState::Failed {
                    tunnel.role_state.lock().on_connection_failed(resource_id);
                    tunnel.peer_connections.lock().remove(&gateway_id);
                }
            })
        },
    ));
}

impl<CB> Tunnel<CB, client::State>
where
    CB: Callbacks + 'static,
{
    /// Initiate an ice connection request.
    ///
    /// Given a resource id and a list of relay creates a [RequestConnection]
    /// and prepares the tunnel to handle the connection once initiated.
    ///
    /// # Parameters
    /// - `resource_id`: Id of the resource we are going to request the connection to.
    /// - `relays`: The list of relays used for that connection.
    ///
    /// # Returns
    /// A [RequestConnection] that should be sent to the gateway through the control-plane.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn request_connection(
        self: &Arc<Self>,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        relays: Vec<Relay>,
        reference: usize,
    ) -> Result<Option<Request>> {
        tracing::trace!("request_connection");

        if let Some(connection) = self.role_state.lock().attempt_to_reuse_connection(
            resource_id,
            gateway_id,
            reference,
            &mut self.peers_by_ip.write(),
        )? {
            return Ok(Some(Request::ReuseConnection(connection)));
        }

        let peer_connection = {
            let (peer_connection, receiver) = new_peer_connection(&self.webrtc_api, relays).await?;
            self.role_state
                .lock()
                .add_waiting_ice_receiver(gateway_id, receiver);
            let peer_connection = Arc::new(peer_connection);
            let mut peer_connections = self.peer_connections.lock();
            peer_connections.insert(gateway_id, Arc::clone(&peer_connection));
            peer_connection
        };

        set_connection_state_update(self, &peer_connection, gateway_id, resource_id);

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

        let preshared_key = StaticSecret::random_from_rng(OsRng);
        let p_key = preshared_key.clone();

        let sender =
            self.role_state
                .lock()
                .register_new_data_channel(resource_id, gateway_id, p_key);

        let d = Arc::clone(&data_channel);

        data_channel.on_open(Box::new(move || {
            Box::pin(async move {
                tracing::trace!("new_data_channel_opened");

                let d = d.detach().await.expect(
                    "only fails if not opened or not enabled, both of which are always true for us",
                );
                let _ = sender.send(d); // Ignore error if receiver is gone.
            })
        }));

        Ok(Some(Request::NewConnection(RequestConnection {
            resource_id,
            gateway_id,
            client_preshared_key: Secret::new(Key(preshared_key.to_bytes())),
            client_rtc_session_description: offer,
        })))
    }

    /// Called when a response to [Tunnel::request_connection] is ready.
    ///
    /// Once this is called, if everything goes fine, a new tunnel should be started between the 2 peers.
    ///
    /// # Parameters
    /// - `resource_id`: Id of the resource that responded.
    /// - `rtc_sdp`: Remote SDP.
    /// - `gateway_public_key`: Public key of the gateway that is handling that resource for this connection.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn received_offer_response(
        &self,
        resource_id: ResourceId,
        rtc_sdp: RTCSessionDescription,
        gateway_public_key: PublicKey,
    ) -> Result<()> {
        let gateway_id = self
            .role_state
            .lock()
            .gateway_by_resource(&resource_id)
            .ok_or(Error::UnknownResource)?;
        let peer_connection = self
            .peer_connections
            .lock()
            .get(&gateway_id)
            .ok_or(Error::UnknownResource)?
            .clone();
        peer_connection.set_remote_description(rtc_sdp).await?;

        self.role_state
            .lock()
            .activate_ice_candidate_receiver(gateway_id, gateway_public_key);

        Ok(())
    }
}
