use std::{sync::Arc, time::Duration};

use crate::messages::{Connect, ConnectionDetails, EgressMessages, InitClient, Messages};
use backoff::{ExponentialBackoff, ExponentialBackoffBuilder};
use boringtun::x25519::StaticSecret;
use libs_common::{
    control::{ErrorInfo, ErrorReply, MessageResult, PhoenixSenderWithTopic},
    messages::{Id, ResourceDescription},
    Callbacks, ControlSession, Error, Result,
};

use async_trait::async_trait;
use firezone_tunnel::{ControlSignal, Request, Tunnel};
use tokio::sync::mpsc::Receiver;

#[async_trait]
impl ControlSignal for ControlSignaler {
    async fn signal_connection_to(
        &self,
        resource: &ResourceDescription,
        connected_gateway_ids: Vec<Id>,
    ) -> Result<()> {
        self.control_signal
            // It's easier if self is not mut
            .clone()
            .send_with_ref(
                EgressMessages::PrepareConnection {
                    resource_id: resource.id(),
                    connected_gateway_ids,
                },
                // The resource id functions as the connection id since we can only have one connection
                // outgoing for each resource.
                resource.id(),
            )
            .await?;
        Ok(())
    }
}

/// Implementation of [ControlSession] for clients.
pub struct ControlPlane<CB: Callbacks> {
    tunnel: Arc<Tunnel<ControlSignaler, CB>>,
    control_signaler: ControlSignaler,
}

#[derive(Clone)]
struct ControlSignaler {
    control_signal: PhoenixSenderWithTopic,
}

impl<CB: Callbacks + 'static> ControlPlane<CB> {
    #[tracing::instrument(level = "trace", skip(self))]
    async fn start(mut self, mut receiver: Receiver<MessageResult<Messages>>) -> Result<()> {
        let mut interval = tokio::time::interval(Duration::from_secs(10));
        loop {
            tokio::select! {
                Some(msg) = receiver.recv() => {
                    match msg {
                        Ok(msg) => self.handle_message(msg).await?,
                        Err(msg_reply) => self.handle_error(msg_reply).await,
                    }
                },
                _ = interval.tick() => self.stats_event().await,
                else => break
            }
        }
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip_all)]
    async fn init(
        &mut self,
        InitClient {
            interface,
            resources,
        }: InitClient,
    ) -> Result<()> {
        if let Err(e) = self.tunnel.set_interface(&interface).await {
            tracing::error!("Couldn't initialize interface: {e}");
            Err(e)
        } else {
            for resource_description in resources {
                self.add_resource(resource_description).await?;
            }
            tracing::info!("Firezoned Started!");
            Ok(())
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    async fn connect(
        &mut self,
        Connect {
            gateway_rtc_session_description,
            resource_id,
            gateway_public_key,
            ..
        }: Connect,
    ) {
        if let Err(e) = self
            .tunnel
            .recieved_offer_response(
                resource_id,
                gateway_rtc_session_description,
                gateway_public_key.0.into(),
            )
            .await
        {
            let _ = self.tunnel.callbacks().on_error(&e);
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    async fn add_resource(&self, resource_description: ResourceDescription) -> Result<()> {
        self.tunnel.add_resource(resource_description).await
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn remove_resource(&self, id: Id) {
        todo!()
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn update_resource(&self, resource_description: ResourceDescription) {
        todo!()
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn connection_details(
        &self,
        ConnectionDetails {
            gateway_id,
            resource_id,
            relays,
            ..
        }: ConnectionDetails,
    ) {
        let tunnel = Arc::clone(&self.tunnel);
        let mut control_signaler = self.control_signaler.clone();
        tokio::spawn(async move {
            let err = match tunnel
                .request_connection(resource_id, gateway_id, relays)
                .await
            {
                Ok(Request::NewConnection(connection_request)) => {
                    if let Err(err) = control_signaler
                        .control_signal
                        // TODO: create a reference number and keep track for the response
                        .send_with_ref(
                            EgressMessages::RequestConnection(connection_request),
                            resource_id,
                        )
                        .await
                    {
                        err
                    } else {
                        return;
                    }
                }
                Ok(Request::ReuseConnection(connection_request)) => {
                    if let Err(err) = control_signaler
                        .control_signal
                        // TODO: create a reference number and keep track for the response
                        .send_with_ref(
                            EgressMessages::ReuseConnection(connection_request),
                            resource_id,
                        )
                        .await
                    {
                        err
                    } else {
                        return;
                    }
                }
                Err(err) => err,
            };

            tunnel.cleanup_connection(resource_id);
            tracing::error!("Error request connection details: {err}");
            let _ = tunnel.callbacks().on_error(&err);
        });
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(super) async fn handle_message(&mut self, msg: Messages) -> Result<()> {
        match msg {
            Messages::Init(init) => self.init(init).await?,
            Messages::ConnectionDetails(connection_details) => {
                self.connection_details(connection_details)
            }
            Messages::Connect(connect) => self.connect(connect).await,
            Messages::ResourceAdded(resource) => self.add_resource(resource).await?,
            Messages::ResourceRemoved(resource) => self.remove_resource(resource.id),
            Messages::ResourceUpdated(resource) => self.update_resource(resource),
        }
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(super) async fn handle_error(&mut self, reply_error: ErrorReply) {
        if matches!(reply_error.error, ErrorInfo::Offline) {
            match reply_error.reference {
                Some(reference) => {
                    let Ok(id) = reference.parse() else {
                        tracing::error!(
                            "An offline error came back with a reference to a non-valid resource id"
                        );
                        let _ = self.tunnel.callbacks().on_error(&Error::ControlProtocolError);
                        return;
                    };
                    // TODO: Rate limit the number of attempts of getting the relays before just trying a local network connection
                    self.tunnel.cleanup_connection(id);
                }
                None => {
                    tracing::error!(
                        "An offline portal error came without a reference that originated the error"
                    );
                    let _ = self
                        .tunnel
                        .callbacks()
                        .on_error(&Error::ControlProtocolError);
                }
            }
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(super) async fn stats_event(&mut self) {
        // TODO
    }
}

#[async_trait]
impl<CB: Callbacks + 'static> ControlSession<Messages, CB> for ControlPlane<CB> {
    #[tracing::instrument(level = "trace", skip(private_key, callbacks))]
    async fn start(
        private_key: StaticSecret,
        receiver: Receiver<MessageResult<Messages>>,
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
        "device"
    }

    fn retry_strategy() -> ExponentialBackoff {
        ExponentialBackoffBuilder::default().build()
    }
}
