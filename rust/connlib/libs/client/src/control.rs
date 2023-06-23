use std::{marker::PhantomData, sync::Arc, time::Duration};

use crate::messages::{Connect, EgressMessages, InitClient, Messages, Relays};
use boringtun::x25519::StaticSecret;
use libs_common::{
    error_type::ErrorType::{Fatal, Recoverable},
    messages::{Id, ResourceDescription},
    Callbacks, ControlSession, Result,
};

use async_trait::async_trait;
use firezone_tunnel::{ControlSignal, Tunnel};
use tokio::sync::mpsc::{channel, Receiver, Sender};

const INTERNAL_CHANNEL_SIZE: usize = 256;

#[async_trait]
impl ControlSignal for ControlSignaler {
    async fn signal_connection_to(&self, resource: &ResourceDescription) -> Result<()> {
        self.internal_sender
            .send(EgressMessages::ListRelays {
                resource_id: resource.id(),
            })
            .await?;
        Ok(())
    }
}

/// Implementation of [ControlSession] for clients.
pub struct ControlPlane<C: Callbacks> {
    tunnel: Arc<Tunnel<ControlSignaler, C>>,
    control_signaler: ControlSignaler,
    _phantom: PhantomData<C>,
}

#[derive(Clone)]
struct ControlSignaler {
    internal_sender: Arc<Sender<EgressMessages>>,
}

impl<C: Callbacks> ControlPlane<C>
where
    C: Send + Sync + 'static,
{
    #[tracing::instrument(level = "trace", skip(self))]
    async fn start(mut self, mut receiver: Receiver<Messages>) {
        let mut interval = tokio::time::interval(Duration::from_secs(10));
        loop {
            tokio::select! {
                Some(msg) = receiver.recv() => self.handle_message(msg).await,
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
            C::on_error(&e, Fatal);
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
            rtc_sdp,
            resource_id,
            gateway_public_key,
        }: Connect,
    ) {
        if let Err(e) = self
            .tunnel
            .recieved_offer_response(resource_id, rtc_sdp, gateway_public_key.0.into())
            .await
        {
            C::on_error(&e, Recoverable);
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
        let control_signaler = self.control_signaler.clone();
        tokio::spawn(async move {
            match tunnel.request_connection(resource_id, relays).await {
                Ok(connection_request) => {
                    if let Err(err) = control_signaler
                        .internal_sender
                        .send(EgressMessages::RequestConnection(connection_request))
                        .await
                    {
                        tunnel.cleanup_connection(resource_id);
                        C::on_error(&err.into(), Recoverable);
                    }
                }
                Err(err) => {
                    tunnel.cleanup_connection(resource_id);
                    C::on_error(&err, Recoverable);
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
    pub(super) async fn stats_event(&mut self) {
        // TODO
    }
}

#[async_trait]
impl<C: Callbacks + Sync + Send + 'static> ControlSession<Messages, EgressMessages>
    for ControlPlane<C>
{
    #[tracing::instrument(level = "trace", skip(private_key))]
    async fn start(
        private_key: StaticSecret,
    ) -> Result<(Sender<Messages>, Receiver<EgressMessages>)> {
        // This is kinda hacky, the buffer size is 1 so that we make sure that we
        // process one message at a time, blocking if a previous message haven't been processed
        // to force queue ordering.
        let (sender, receiver) = channel::<Messages>(1);

        let (internal_sender, internal_receiver) = channel(INTERNAL_CHANNEL_SIZE);
        let internal_sender = Arc::new(internal_sender);
        let control_signaler = ControlSignaler { internal_sender };
        let tunnel = Arc::new(Tunnel::new(private_key, control_signaler.clone()).await?);

        let control_plane = ControlPlane::<C> {
            tunnel,
            control_signaler,
            _phantom: PhantomData,
        };

        tokio::spawn(async move { control_plane.start(receiver).await });

        Ok((sender, internal_receiver))
    }

    fn socket_path() -> &'static str {
        "device"
    }
}
