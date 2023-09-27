use super::messages::{
    ConnectionReady, EgressMessages, IngressMessages, InitGateway, RequestConnection,
};
use crate::messages::AllowAccess;
use async_trait::async_trait;
use firezone_tunnel::{ControlSignal, Tunnel};
use libs_common::{
    control::PhoenixSenderWithTopic,
    messages::{Id, ResourceDescription},
    Callbacks, Result,
};
use std::sync::Arc;

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
        _connected_gateway_ids: &[Id],
        _: usize,
    ) -> Result<()> {
        tracing::warn!("A message to network resource: {resource:?} was discarded, gateways aren't meant to be used as clients.");
        Ok(())
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
                        tunnel.cleanup_connection(connection_request.client.id);
                        let _ = tunnel.callbacks().on_error(&err);
                    }
                }
                Err(err) => {
                    tunnel.cleanup_connection(connection_request.client.id);
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
        }
        Ok(())
    }

    pub async fn stats_event(&mut self) {
        tracing::debug!(target: "tunnel_state", "{:#?}", self.tunnel.stats());
    }
}
