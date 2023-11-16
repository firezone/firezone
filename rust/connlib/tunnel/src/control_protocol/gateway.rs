use crate::{gateway, PeerConfig, Tunnel};
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ClientId, Relay, ResourceDescription},
    Callbacks, Result,
};
use std::sync::Arc;
use str0m::ice::IceCreds;
use str0m::Candidate;

impl<CB> Tunnel<CB, gateway::State>
where
    CB: Callbacks + 'static,
{
    pub fn add_ice_candidate(&self, client: ClientId, candidate: Candidate) {
        self.role_state
            .lock()
            .add_remote_candidate(client, candidate);
    }

    /// Accept a connection request from a client.
    pub fn set_peer_connection_request(
        self: &Arc<Self>,
        remote_credentials: IceCreds,
        peer: PeerConfig,
        relays: Vec<Relay>,
        client_id: ClientId,
        _expires_at: DateTime<Utc>,
        _resource: ResourceDescription, // TODO: Do I need to use this? I think we concluded that we will receive another `allow_access` call from the portal later.
    ) -> Result<IceCreds> {
        let local_params = self.role_state.lock().make_new_connection(
            self.ip4_socket.local_addr()?, // TODO: We also need to handle IPv6 here!
            client_id,
            relays,
            remote_credentials,
            peer.preshared_key,
            peer.public_key,
            peer.ips,
        );

        Ok(local_params)
    }

    pub fn allow_access(
        &self,
        resource: ResourceDescription,
        client_id: ClientId,
        expires_at: DateTime<Utc>,
    ) {
        self.role_state
            .lock()
            .allow_access(client_id, resource, expires_at);
    }
}
