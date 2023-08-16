use std::{sync::Arc, time::Duration};

use backoff::{ExponentialBackoff, ExponentialBackoffBuilder};
use boringtun::x25519::StaticSecret;
use firezone_tunnel::{ControlSignal, Tunnel};
use libs_common::{
    control::{MessageResult, PhoenixSenderWithTopic},
    messages::{Id, ResourceDescription},
    Callbacks, ControlSession, Result,
};
use tokio::sync::mpsc::Receiver;

use crate::messages::AllowAccess;

use super::messages::{
    ConnectionReady, EgressMessages, IngressMessages, InitGateway, RequestConnection,
};

use async_trait::async_trait;

pub struct ControlPlane<CB: Callbacks> {
    tunnel: Arc<Tunnel<ControlSignaler, CB>>,
    control_signaler: ControlSignaler,
}

#[derive(Clone)]
struct ControlSignaler {
    control_signal: PhoenixSenderWithTopic,
}

#[async_trait]
impl ControlSignal for ControlSignaler {
    async fn signal_connection_to(
        &self,
        resource: &ResourceDescription,
        _connected_gateway_ids: Vec<Id>,
    ) -> Result<()> {
        tracing::warn!("A message to network resource: {resource:?} was discarded, gateways aren't meant to be used as clients.");
        Ok(())
    }
}

impl<CB: Callbacks + 'static> ControlPlane<CB> {
    #[tracing::instrument(level = "trace", skip(self))]
    async fn start(mut self, mut receiver: Receiver<MessageResult<IngressMessages>>) -> Result<()> {
        let mut interval = tokio::time::interval(Duration::from_secs(10));
        loop {
            tokio::select! {
                Some(msg) = receiver.recv() => {
                    match msg {
                        Ok(msg) => self.handle_message(msg).await?,
                        Err(_msg_reply) => todo!(),
                    }
                },
                _ = interval.tick() => self.stats_event().await,
                else => break
            }
        }
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip_all)]
    async fn init(&mut self, init: InitGateway) -> Result<()> {
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
    fn connection_request(&self, connection_request: RequestConnection) {
        let tunnel = Arc::clone(&self.tunnel);
        let mut control_signaler = self.control_signaler.clone();
        tokio::spawn(async move {
            match tunnel
                .set_peer_connection_request(
                    connection_request.device.rtc_session_description,
                    connection_request.device.peer.into(),
                    connection_request.relays,
                    connection_request.device.id,
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
                        tunnel.cleanup_connection(connection_request.device.id);
                        let _ = tunnel.callbacks().on_error(&err);
                    }
                }
                Err(err) => {
                    tunnel.cleanup_connection(connection_request.device.id);
                    let _ = tunnel.callbacks().on_error(&err);
                }
            }
        });
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn allow_access(
        &self,
        AllowAccess {
            device_id,
            resource,
            expires_at,
        }: AllowAccess,
    ) {
        self.tunnel.allow_access(resource, device_id, expires_at)
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(super) async fn handle_message(&mut self, msg: IngressMessages) -> Result<()> {
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

    #[tracing::instrument(level = "trace", skip(self))]
    pub(super) async fn stats_event(&mut self) {
        tracing::debug!("TODO: STATS EVENT");
    }
}

#[async_trait]
impl<CB: Callbacks + 'static> ControlSession<IngressMessages, CB> for ControlPlane<CB> {
    #[tracing::instrument(level = "trace", skip(private_key, callbacks))]
    async fn start(
        private_key: StaticSecret,
        receiver: Receiver<MessageResult<IngressMessages>>,
        control_signal: PhoenixSenderWithTopic,
        callbacks: CB,
    ) -> Result<()> {
        let control_signaler = ControlSignaler { control_signal };
        let tunnel = Arc::new(Tunnel::new(private_key, control_signaler.clone(), callbacks).await?);

        let control_plane = ControlPlane {
            tunnel,
            control_signaler,
        };

        tokio::spawn(async move { control_plane.start(receiver).await });

        Ok(())
    }

    fn socket_path() -> &'static str {
        "gateway"
    }

    fn retry_strategy() -> ExponentialBackoff {
        ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(None)
            .build()
    }
}
