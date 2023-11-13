use async_compression::tokio::bufread::GzipEncoder;
use connlib_shared::messages::{RequestConnection, ReuseConnection};
use std::io;
use std::path::PathBuf;

use crate::messages::{
    BroadcastGatewayIceCandidates, Connect, ConnectionDetails, EgressMessages,
    GatewayIceCandidates, InitClient, Messages,
};
use connlib_shared::{
    control::{ErrorInfo, ErrorReply, PhoenixSenderWithTopic, Reference},
    messages::{ResourceDescription, ResourceId},
    Callbacks,
    Error::{self},
    Result,
};

use firezone_tunnel::{client, Tunnel};
use reqwest::header::{CONTENT_ENCODING, CONTENT_TYPE};
use tokio::io::BufReader;
use tokio::sync::Mutex;
use tokio_util::codec::{BytesCodec, FramedRead};
use url::Url;

pub struct ControlPlane<CB: Callbacks> {
    pub tunnel: Tunnel<CB, client::State>,
    pub phoenix_channel: PhoenixSenderWithTopic,
    pub tunnel_init: Mutex<bool>,
}

impl<CB: Callbacks + 'static> ControlPlane<CB> {
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
    pub async fn connect(
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
    pub async fn add_resource(&self, resource_description: ResourceDescription) {
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
        let Some(Ok(reference)) = reference.clone().map(|r| r.parse()) else {
            tracing::warn!("Failed to parse {reference:?} as usize");
            return;
        };

        if let Err(err) = self
            .tunnel
            .request_connection(resource_id, gateway_id, relays, reference)
        {
            self.tunnel.cleanup_connection(resource_id);
            tracing::error!("Error request connection details: {err}");
            let _ = self.tunnel.callbacks().on_error(&err);
        }
    }

    async fn add_ice_candidate(
        &self,
        GatewayIceCandidates {
            gateway_id,
            candidates,
        }: GatewayIceCandidates,
    ) {
        for candidate in candidates {
            if let Err(e) = self.tunnel.add_ice_candidate(gateway_id, candidate).await {
                tracing::error!(err = ?e,"add_ice_candidate");
                let _ = self.tunnel.callbacks().on_error(&e);
            }
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn handle_message(
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
            Messages::SignedLogUrl(url) => {
                let Some(path) = self.tunnel.callbacks().roll_log_file() else {
                    return Ok(());
                };

                tokio::spawn(async move {
                    if let Err(e) = upload(path.clone(), url).await {
                        tracing::warn!("Failed to upload log file: {e}");
                        return;
                    }
                    if let Err(e) = tokio::fs::remove_file(&path).await {
                        tracing::warn!("Failed to upload log file: {e}")
                    }
                });
            }
        }
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn handle_error(&mut self, reply_error: ErrorReply, reference: Option<Reference>) {
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
                    self.tunnel.cleanup_connection(resource_id);
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

    pub async fn stats_event(&mut self) {
        tracing::debug!(target: "tunnel_state", stats = ?self.tunnel.stats());
    }

    pub async fn request_log_upload_url(&mut self) {
        tracing::info!("Requesting log upload URL from portal");

        let _ = self
            .phoenix_channel
            .send(EgressMessages::CreateLogSink {})
            .await;
    }

    pub async fn handle_tunnel_event(&mut self, event: Result<client::Event>) {
        match event {
            Ok(client::Event::SignalIceCandidate { conn_id, candidate }) => {
                if let Err(e) = self
                    .phoenix_channel
                    .send(EgressMessages::BroadcastIceCandidates(
                        BroadcastGatewayIceCandidates {
                            gateway_ids: vec![conn_id],
                            candidates: vec![candidate],
                        },
                    ))
                    .await
                {
                    tracing::error!("Failed to signal ICE candidate: {e}")
                }
            }
            Ok(client::Event::ConnectionIntent {
                resource,
                connected_gateway_ids,
                reference,
            }) => {
                if let Err(e) = self
                    .phoenix_channel
                    .clone()
                    .send_with_ref(
                        EgressMessages::PrepareConnection {
                            resource_id: resource.id(),
                            connected_gateway_ids,
                        },
                        reference,
                    )
                    .await
                {
                    tracing::error!("Failed to prepare connection: {e}");

                    // TODO: Clean up connection in `ClientState` here?
                }
            }
            Err(e) => {
                tracing::error!("Tunnel failed: {e}");
            }
            Ok(client::Event::NewConnection {
                gateway,
                resource,
                key,
                desc,
            }) => {
                if let Err(err) = self
                    .phoenix_channel
                    // TODO: create a reference number and keep track for the response
                    .send_with_ref(
                        EgressMessages::RequestConnection(RequestConnection {
                            gateway_id: gateway,
                            resource_id: resource,
                            client_preshared_key: key,
                            client_rtc_session_description: desc,
                        }),
                        resource,
                    )
                    .await
                {
                    self.tunnel.cleanup_connection(resource);
                    tracing::error!("Failed to request connection: {err}");
                }
            }
            Ok(client::Event::ReuseConnection { gateway, resource }) => {
                if let Err(err) = self
                    .phoenix_channel
                    // TODO: create a reference number and keep track for the response
                    .send_with_ref(
                        EgressMessages::ReuseConnection(ReuseConnection {
                            resource_id: resource,
                            gateway_id: gateway,
                        }),
                        resource,
                    )
                    .await
                {
                    self.tunnel.cleanup_connection(resource);
                    tracing::error!("Failed to request connection: {err}");
                }
            }
        }
    }
}

async fn upload(path: PathBuf, url: Url) -> io::Result<()> {
    tracing::info!(path = %path.display(), %url, "Uploading log file");

    let file = tokio::fs::File::open(&path).await?;

    let response = reqwest::Client::new()
        .put(url)
        .header(CONTENT_TYPE, "text/plain")
        .header(CONTENT_ENCODING, "gzip")
        .body(reqwest::Body::wrap_stream(FramedRead::new(
            GzipEncoder::new(BufReader::new(file)),
            BytesCodec::default(),
        )))
        .send()
        .await
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;

    let status_code = response.status();

    if !status_code.is_success() {
        let body = response
            .text()
            .await
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;

        tracing::warn!(%body, %status_code, "Failed to upload logs");

        return Err(io::Error::new(
            io::ErrorKind::Other,
            "portal returned non-successful exit code",
        ));
    }

    Ok(())
}
