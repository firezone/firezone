use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ClientId, Relay, ResourceDescription},
    Callbacks,
};
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use crate::{gateway, PeerConfig, Tunnel};

impl<CB> Tunnel<CB, gateway::State>
where
    CB: Callbacks + 'static,
{
    /// Accept a connection request from a client.
    #[allow(clippy::too_many_arguments)]
    pub fn set_peer_connection_request(
        &self,
        client_id: ClientId,
        phoenix_reference: String,
        sdp_session: RTCSessionDescription,
        peer: PeerConfig,
        relays: Vec<Relay>,
        expires_at: DateTime<Utc>,
        resource: ResourceDescription,
    ) {
        self.role_state.lock().new_peer_connection(
            client_id,
            phoenix_reference,
            peer,
            resource,
            expires_at,
            self.webrtc_api.clone(),
            relays,
            sdp_session,
        );
    }

    pub fn allow_access(
        &self,
        resource: ResourceDescription,
        client_id: ClientId,
        expires_at: DateTime<Utc>,
    ) {
        if let Some((_, peer)) = self
            .peers_by_ip
            .write()
            .iter_mut()
            .find(|(_, p)| p.inner.conn_id == client_id)
        {
            peer.inner.add_resource(resource, expires_at);
        }
    }
}
