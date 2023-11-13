use boringtun::x25519::PublicKey;
use connlib_shared::{
    messages::{GatewayId, Relay, ResourceId},
    Callbacks,
};
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use crate::{client, Error, Request, Result, Tunnel};

impl<CB> Tunnel<CB, client::State>
where
    CB: Callbacks + 'static,
{
    /// Initiate an ice connection request.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn request_connection(
        &self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        relays: Vec<Relay>,
        reference: usize,
    ) -> Result<Option<Request>> {
        tracing::trace!("request_connection");

        let mut role_state = self.role_state.lock();

        if let Some(connection) = role_state.attempt_to_reuse_connection(
            resource_id,
            gateway_id,
            reference,
            &mut self.peers_by_ip.write(),
        )? {
            return Ok(Some(Request::ReuseConnection(connection)));
        }

        role_state.new_peer_connection(self.webrtc_api.clone(), relays, resource_id, gateway_id);

        Ok(None)
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
