use std::{sync::Arc, time::Duration};

use crate::messages::{Connect, EgressMessages, InitClient, Messages, Relays};
use boringtun::x25519::StaticSecret;
use libs_common::{
    control::{ErrorInfo, ErrorReply, MessageResult, PhoenixSenderWithTopic},
    error_type::ErrorType::{self, Fatal, Recoverable},
    messages::{Id, ResourceDescription},
    Callbacks, ControlSession, Error, Result,
};

use async_trait::async_trait;
use firezone_tunnel::{ControlSignal, Tunnel};
use tokio::sync::mpsc::Receiver;

#[async_trait]
impl ControlSignal for ControlSignaler {
    async fn signal_connection_to(&self, resource: &ResourceDescription) -> Result<()> {
        self.control_signal
            // It's easier if self is not mut
            .clone()
            .send_with_ref(
                EgressMessages::ListRelays {
                    resource_id: resource.id(),
                },
                // The resource id functions as the connection id since we can only have one connection
                // outgoing for each resource.
                resource.id().to_string(),
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
    async fn start(mut self, mut receiver: Receiver<MessageResult<Messages>>) {
        let mut interval = tokio::time::interval(Duration::from_secs(10));
        loop {
            tokio::select! {
                Some(msg) = receiver.recv() => {
                    match msg {
                        Ok(msg) => self.handle_message(msg).await,
                        Err(msg_reply) => self.handle_error(msg_reply).await,
                    }
                },
                _ = interval.tick() => self.stats_event().await,
                else => break
            }
        }
    }

    #[tracing::instrument(level = "trace", skip_all)]
    async fn init(
        &mut self,
        InitClient {
            interface,
            resources,
        }: InitClient,
    ) {
        if let Err(e) = self.tunnel.set_interface(&interface).await {
            tracing::error!("Couldn't initialize interface: {e}");
            self.tunnel.callbacks().on_error(&e, Fatal);
            return;
        }

        for resource_description in resources {
            self.add_resource(resource_description).await
        }

        tracing::info!("Firezoned Started!");
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
            self.tunnel.callbacks().on_error(&e, Recoverable);
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    async fn add_resource(&self, resource_description: ResourceDescription) {
        self.tunnel.add_resource(resource_description).await;
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
    fn relays(
        &self,
        Relays {
            resource_id,
            relays,
        }: Relays,
    ) {
        let tunnel = Arc::clone(&self.tunnel);
        let mut control_signaler = self.control_signaler.clone();
        tokio::spawn(async move {
            match tunnel.request_connection(resource_id, relays).await {
                Ok(connection_request) => {
                    if let Err(err) = control_signaler
                        .control_signal
                        // TODO: create a reference number and keep track for the response
                        .send_with_ref(
                            EgressMessages::RequestConnection(connection_request),
                            resource_id.to_string(),
                        )
                        .await
                    {
                        tunnel.cleanup_connection(resource_id);
                        tunnel.callbacks().on_error(&err, Recoverable);
                    }
                }
                Err(err) => {
                    tunnel.cleanup_connection(resource_id);
                    tunnel.callbacks().on_error(&err, Recoverable);
                }
            }
        });
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(super) async fn handle_message(&mut self, msg: Messages) {
        match msg {
            Messages::Init(init) => self.init(init).await,
            Messages::Relays(connection_details) => self.relays(connection_details),
            Messages::Connect(connect) => self.connect(connect).await,
            Messages::ResourceAdded(resource) => self.add_resource(resource).await,
            Messages::ResourceRemoved(resource) => self.remove_resource(resource.id),
            Messages::ResourceUpdated(resource) => self.update_resource(resource),
        }
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
                        self.tunnel.callbacks().on_error(&Error::ControlProtocolError, ErrorType::Recoverable);
                        return;
                    };
                    // TODO: Rate limit the number of attemps of getting the relays before just trying a local network connection
                    self.tunnel.cleanup_connection(id);
                }
                None => {
                    tracing::error!(
                    "An offline portal error came without a reference that originated the error"
                );
                    self.tunnel
                        .callbacks()
                        .on_error(&Error::ControlProtocolError, ErrorType::Recoverable);
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
}
