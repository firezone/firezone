use super::messages::{
    ConnectionReady, EgressMessages, IngressMessages, InitGateway, RequestConnection,
};
use crate::messages::{AllowAccess, BroadcastClientIceCandidates, ClientIceCandidates};
use async_trait::async_trait;
use connlib_shared::Error::ControlProtocolError;
use connlib_shared::{
    control::PhoenixSenderWithTopic,
    messages::{GatewayId, ResourceDescription},
    Callbacks, Result,
};
use firezone_tunnel::{ConnId, ControlSignal, Tunnel};
use std::sync::Arc;
use webrtc::ice_transport::ice_candidate::RTCIceCandidate;

pub struct ControlPlane<CB: Callbacks> {
    pub tunnel: Arc<Tunnel<ControlSignaler, CB>>,
    pub control_signaler: ControlSignaler,
}

#[derive(Clone)]
pub struct ControlSignaler {
    pub control_signal: PhoenixSenderWithTopic,
}

#[async_trait]
impl ControlSignal for ControlSignaler {
    async fn signal_connection_to(
        &self,
        resource: &ResourceDescription,
        _connected_gateway_ids: &[GatewayId],
        _: usize,
    ) -> Result<()> {
        tracing::warn!("A message to network resource: {resource:?} was discarded, gateways aren't meant to be used as clients.");
        Ok(())
    }

    async fn signal_ice_candidate(
        &self,
        ice_candidate: RTCIceCandidate,
        conn_id: ConnId,
    ) -> Result<()> {
        // TODO: We probably want to have different signal_ice_candidate
        // functions for gateway/client but ultimately we just want
        // separate control_plane modules
        if let ConnId::Client(id) = conn_id {
            self.control_signal
                .clone()
                .send(EgressMessages::BroadcastIceCandidates(
                    BroadcastClientIceCandidates {
                        client_ids: vec![id],
                        candidates: vec![ice_candidate.to_json()?],
                    },
                ))
                .await?;

            Ok(())
        } else {
            Err(ControlProtocolError)
        }
    }
}

impl<CB: Callbacks + 'static> ControlPlane<CB> {
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn init(&mut self, init: InitGateway) -> Result<()> {
        if let Err(e) = self.tunnel.set_interface(&init.interface).await {
            tracing::error!("Couldn't initialize interface: {e}");
            Err(e)
        } else {
            // TODO: Enable masquerading here.
            tracing::info!("Firezoned Started!");
            Ok(())
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn connection_request(&self, connection_request: RequestConnection) {
        let tunnel = Arc::clone(&self.tunnel);
        let mut control_signaler = self.control_signaler.clone();
        tokio::spawn(async move {
            match tunnel
                .set_peer_connection_request(
                    connection_request.client.rtc_session_description,
                    connection_request.client.peer.into(),
                    connection_request.relays,
                    connection_request.client.id,
                    connection_request.expires_at,
                    connection_request.resource,
                )
                .await
            {
                Ok(gateway_rtc_session_description) => {
                    if let Err(err) = control_signaler
                        .control_signal
                        .send(EgressMessages::ConnectionReady(ConnectionReady {
                            reference: connection_request.reference,
                            gateway_rtc_session_description,
                        }))
                        .await
                    {
                        tunnel.cleanup_connection(connection_request.client.id.into());
                        let _ = tunnel.callbacks().on_error(&err);
                    }
                }
                Err(err) => {
                    tunnel.cleanup_connection(connection_request.client.id.into());
                    let _ = tunnel.callbacks().on_error(&err);
                }
            }
        });
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn allow_access(
        &self,
        AllowAccess {
            client_id,
            resource,
            expires_at,
        }: AllowAccess,
    ) {
        self.tunnel.allow_access(resource, client_id, expires_at)
    }

    async fn add_ice_candidate(
        &self,
        ClientIceCandidates {
            client_id,
            candidates,
        }: ClientIceCandidates,
    ) {
        for candidate in candidates {
            if let Err(e) = self
                .tunnel
                .add_ice_candidate(client_id.into(), candidate)
                .await
            {
                tracing::error!(err = ?e,"add_ice_candidate");
                let _ = self.tunnel.callbacks().on_error(&e);
            }
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn handle_message(&mut self, msg: IngressMessages) -> Result<()> {
        match msg {
            IngressMessages::Init(init) => self.init(init).await?,
            IngressMessages::RequestConnection(connection_request) => {
                self.connection_request(connection_request)
            }
            IngressMessages::AllowAccess(allow_access) => {
                self.allow_access(allow_access);
            }

            IngressMessages::IceCandidates(ice_candidate) => {
                self.add_ice_candidate(ice_candidate).await
            }
        }
        Ok(())
    }

    pub async fn stats_event(&mut self) {
        tracing::debug!(target: "tunnel_state", stats = ?self.tunnel.stats());
    }
}
