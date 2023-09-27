use std::{sync::Arc, time::Duration};

use crate::messages::{
    BroadcastGatewayIceCandidates, Connect, ConnectionDetails, EgressMessages,
    GatewayIceCandidates, InitClient, Messages,
};
use backoff::{ExponentialBackoff, ExponentialBackoffBuilder};
use boringtun::x25519::StaticSecret;
use libs_common::{
    control::{ErrorInfo, ErrorReply, MessageResult, PhoenixSenderWithTopic, Reference},
    messages::{GatewayId, ResourceDescription, ResourceId},
    Callbacks, ControlSession,
    Error::{self, ControlProtocolError},
    Result,
};
use webrtc::ice_transport::ice_candidate::RTCIceCandidate;

use async_trait::async_trait;
use firezone_tunnel::{ConnId, ControlSignal, Request, Tunnel};
use tokio::sync::{mpsc::Receiver, Mutex};

#[async_trait]
impl ControlSignal for ControlSignaler {
    async fn signal_connection_to(
        &self,
        resource: &ResourceDescription,
        connected_gateway_ids: &[GatewayId],
        reference: usize,
    ) -> Result<()> {
        self.control_signal
            // It's easier if self is not mut
            .clone()
            .send_with_ref(
                EgressMessages::PrepareConnection {
                    resource_id: resource.id(),
                    connected_gateway_ids: connected_gateway_ids.to_vec(),
                },
                reference,
            )
            .await?;
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
        if let ConnId::Gateway(id) = conn_id {
            self.control_signal
                .clone()
                .send(EgressMessages::BroadcastIceCandidates(
                    BroadcastGatewayIceCandidates {
                        gateway_ids: vec![id],
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

/// Implementation of [ControlSession] for clients.
pub struct ControlPlane<CB: Callbacks> {
    tunnel: Arc<Tunnel<ControlSignaler, CB>>,
    control_signaler: ControlSignaler,
    tunnel_init: Mutex<bool>,
}

#[derive(Clone)]
struct ControlSignaler {
    control_signal: PhoenixSenderWithTopic,
}

impl<CB: Callbacks + 'static> ControlPlane<CB> {
    #[tracing::instrument(level = "trace", skip(self))]
    async fn start(
        mut self,
        mut receiver: Receiver<(MessageResult<Messages>, Option<Reference>)>,
    ) -> Result<()> {
        let mut interval = tokio::time::interval(Duration::from_secs(10));
        loop {
            tokio::select! {
                Some((msg, reference)) = receiver.recv() => {
                    match msg {
                        Ok(msg) => self.handle_message(msg, reference).await?,
                        Err(err) => self.handle_error(err, reference).await,
                    }
                },
                _ = interval.tick() => self.stats_event().await,
                else => break
            }
        }
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    async fn init(
        &mut self,
        InitClient {
            interface,
            resources,
        }: InitClient,
    ) -> Result<()> {
        {
            let mut init = self.tunnel_init.lock().await;
            if !*init {
                if let Err(e) = self.tunnel.set_interface(&interface).await {
                    tracing::error!(error = ?e, "Error initializing interface");
                    return Err(e);
                } else {
                    *init = true;
                    tracing::info!("Firezoned Started!");
                }
            } else {
                tracing::info!("Firezoned reinitializated");
            }
        }

        for resource_description in resources {
            self.add_resource(resource_description).await;
        }
        Ok(())
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
            .received_offer_response(
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
    async fn add_resource(&self, resource_description: ResourceDescription) {
        if let Err(e) = self.tunnel.add_resource(resource_description).await {
            tracing::error!(message = "Can't add resource", error = ?e);
            let _ = self.tunnel.callbacks().on_error(&e);
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn remove_resource(&self, id: ResourceId) {
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
        reference: Option<Reference>,
    ) {
        let tunnel = Arc::clone(&self.tunnel);
        let mut control_signaler = self.control_signaler.clone();
        tokio::spawn(async move {
            let err = match tunnel
                .request_connection(resource_id, gateway_id, relays, reference)
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

            tunnel.cleanup_connection(resource_id.into());
            tracing::error!("Error request connection details: {err}");
            let _ = tunnel.callbacks().on_error(&err);
        });
    }

    async fn add_ice_candidate(
        &self,
        GatewayIceCandidates {
            gateway_id,
            candidates,
        }: GatewayIceCandidates,
    ) {
        for candidate in candidates {
            if let Err(e) = self
                .tunnel
                .add_ice_candidate(gateway_id.into(), candidate)
                .await
            {
                tracing::error!(err = ?e,"add_ice_candidate");
                let _ = self.tunnel.callbacks().on_error(&e);
            }
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(super) async fn handle_message(
        &mut self,
        msg: Messages,
        reference: Option<Reference>,
    ) -> Result<()> {
        match msg {
            Messages::Init(init) => self.init(init).await?,
            Messages::ConnectionDetails(connection_details) => {
                self.connection_details(connection_details, reference)
            }
            Messages::Connect(connect) => self.connect(connect).await,
            Messages::ResourceAdded(resource) => self.add_resource(resource).await,
            Messages::ResourceRemoved(resource) => self.remove_resource(resource.id),
            Messages::ResourceUpdated(resource) => self.update_resource(resource),
            Messages::IceCandidates(ice_candidate) => self.add_ice_candidate(ice_candidate).await,
        }
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(super) async fn handle_error(
        &mut self,
        reply_error: ErrorReply,
        reference: Option<Reference>,
    ) {
        if matches!(reply_error.error, ErrorInfo::Offline) {
            match reference {
                Some(reference) => {
                    let Ok(resource_id) = reference.parse::<ResourceId>() else {
                        tracing::error!(
                            "An offline error came back with a reference to a non-valid resource id"
                        );
                        let _ = self
                            .tunnel
                            .callbacks()
                            .on_error(&Error::ControlProtocolError);
                        return;
                    };
                    // TODO: Rate limit the number of attempts of getting the relays before just trying a local network connection
                    self.tunnel.cleanup_connection(resource_id.into());
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

    pub(super) async fn stats_event(&mut self) {
        tracing::debug!(target: "tunnel_state", stats = ?self.tunnel.stats());
    }
}

#[async_trait]
impl<CB: Callbacks + 'static> ControlSession<Messages, CB> for ControlPlane<CB> {
    #[tracing::instrument(level = "trace", skip(private_key, callbacks))]
    async fn start(
        private_key: StaticSecret,
        receiver: Receiver<(MessageResult<Messages>, Option<Reference>)>,
        control_signal: PhoenixSenderWithTopic,
        callbacks: CB,
    ) -> Result<()> {
        let control_signaler = ControlSignaler { control_signal };
        let tunnel = Arc::new(Tunnel::new(private_key, control_signaler.clone(), callbacks).await?);

        let control_plane = ControlPlane {
            tunnel,
            control_signaler,
            tunnel_init: Mutex::new(false),
        };

        tokio::spawn(async move { control_plane.start(receiver).await });

        Ok(())
    }

    fn socket_path() -> &'static str {
        "client"
    }

    fn retry_strategy() -> ExponentialBackoff {
        ExponentialBackoffBuilder::default().build()
    }
}
