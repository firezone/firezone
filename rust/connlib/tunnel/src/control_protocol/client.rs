use std::sync::Arc;

use boringtun::x25519::PublicKey;
use connlib_shared::messages::{ClientPayload, DomainResponse};
use connlib_shared::Result;
use connlib_shared::{
    messages::{GatewayId, Relay, RequestConnection, ResourceId},
    Callbacks,
};
use str0m::ice::IceCreds;
use str0m::Candidate;

use crate::{client, Request, Tunnel};

impl<CB> Tunnel<CB, client::State>
where
    CB: Callbacks + 'static,
{
    pub fn add_ice_candidate(&self, conn_id: GatewayId, candidate: Candidate) {
        self.role_state
            .lock()
            .add_remote_candidate(conn_id, candidate);
    }

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
    #[tracing::instrument(level = "trace", skip(self, relays, resource_id, gateway_id), fields(%resource_id, %gateway_id))]
    pub fn request_connection(
        &self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        relays: Vec<Relay>,
    ) -> Result<Request> {
        if let Some(connection) = self
            .role_state
            .lock()
            .attempt_to_reuse_connection(resource_id, gateway_id)?
        {
            return Ok(Request::ReuseConnection(connection));
        }

        let (preshared_key, ice_params) = self.role_state.lock().make_new_connection(
            self.ip4_socket.local_addr()?,
            gateway_id,
            relays,
        );

        Ok(Request::NewConnection(RequestConnection {
            resource_id,
            gateway_id,
            client_preshared_key: preshared_key,
            client_payload: ClientPayload {
                ice_parameters: ice_params,
                domain: None,
            },
        }))
    }

    /// Called when a response to [Tunnel::request_connection] is ready.
    ///
    /// Once this is called, if everything goes fine, a new tunnel should be started between the 2 peers.
    ///
    /// # Parameters
    /// - `resource_id`: Id of the resource that responded.
    /// - `rtc_sdp`: Remote SDP.
    /// - `gateway_public_key`: Public key of the gateway that is handling that resource for this connection.
    pub fn received_offer_response(
        self: &Arc<Self>,
        resource_id: ResourceId,
        remote_credentials: IceCreds,
        domain_response: Option<DomainResponse>,
        gateway_public_key: PublicKey,
    ) -> Result<()> {
        self.role_state.lock().set_remote_credentials(
            resource_id,
            gateway_public_key,
            remote_credentials,
        )?;

        Ok(())
    }
}
