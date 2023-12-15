use async_compression::tokio::bufread::GzipEncoder;
use connlib_shared::control::KnownError;
use connlib_shared::control::Reason;
use connlib_shared::messages::{DnsServer, GatewayResponse, IpDnsServer};
use std::path::PathBuf;
use std::{io, sync::Arc};

use crate::messages::{
    BroadcastGatewayIceCandidates, Connect, ConnectionDetails, EgressMessages,
    GatewayIceCandidates, InitClient, Messages,
};
use connlib_shared::{
    control::{ErrorInfo, ErrorReply, PhoenixSenderWithTopic, Reference},
    messages::{GatewayId, ResourceDescription, ResourceId},
    Callbacks,
    Error::{self},
    Result,
};

use firezone_tunnel::{ClientState, Request, Tunnel};
use hickory_resolver::config::{NameServerConfig, Protocol, ResolverConfig};
use hickory_resolver::TokioAsyncResolver;
use reqwest::header::{CONTENT_ENCODING, CONTENT_TYPE};
use tokio::io::BufReader;
use tokio::sync::Mutex;
use tokio_util::codec::{BytesCodec, FramedRead};
use url::Url;

const DNS_PORT: u16 = 53;
pub struct ControlPlane<CB: Callbacks> {
    pub tunnel: Arc<Tunnel<CB, ClientState>>,
    pub phoenix_channel: PhoenixSenderWithTopic,
    pub tunnel_init: Mutex<bool>,
    // It's a Mutex<Option<_>> because we need the init message to initialize the resolver
    // also, in platforms with split DNS and no configured upstream dns this will be None.
    //
    // We could still initialize the resolver with no nameservers in those platforms...
    pub fallback_resolver: parking_lot::Mutex<Option<TokioAsyncResolver>>,
}

fn create_resolver(
    upstream_dns: Vec<DnsServer>,
    callbacks: &impl Callbacks,
) -> Option<TokioAsyncResolver> {
    let dns_servers = if upstream_dns.is_empty() {
        let Ok(Some(dns_servers)) = callbacks.get_system_default_resolvers() else {
            return None;
        };
        if dns_servers.is_empty() {
            return None;
        }
        dns_servers
            .into_iter()
            .map(|ip| {
                DnsServer::IpPort(IpDnsServer {
                    address: (ip, DNS_PORT).into(),
                })
            })
            .collect()
    } else {
        upstream_dns
    };

    let mut resolver_config = ResolverConfig::new();
    for srv in dns_servers.iter() {
        let name_server = match srv {
            DnsServer::IpPort(srv) => NameServerConfig::new(srv.address, Protocol::Udp),
        };

        resolver_config.add_name_server(name_server);
    }

    Some(TokioAsyncResolver::tokio(
        resolver_config,
        Default::default(),
    ))
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
                if let Err(e) = self.tunnel.set_interface(&interface) {
                    tracing::error!(error = ?e, "Error initializing interface");
                    return Err(e);
                } else {
                    *init = true;
                    *self.fallback_resolver.lock() =
                        create_resolver(interface.upstream_dns, self.tunnel.callbacks());
                    tracing::info!("Firezone Started!");
                }
            } else {
                tracing::info!("Firezone reinitializated");
            }
        }

        for resource_description in resources {
            self.add_resource(resource_description);
        }
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn connect(
        &mut self,
        Connect {
            gateway_payload,
            resource_id,
            gateway_public_key,
            ..
        }: Connect,
    ) {
        match gateway_payload {
            GatewayResponse::ConnectionAccepted(gateway_payload) => {
                if let Err(e) = self.tunnel.received_offer_response(
                    resource_id,
                    gateway_payload.ice_parameters,
                    gateway_payload.domain_response,
                    gateway_public_key.0.into(),
                ) {
                    let _ = self.tunnel.callbacks().on_error(&e);
                }
            }
            GatewayResponse::ResourceAccepted(gateway_payload) => {
                if let Err(e) = self
                    .tunnel
                    .received_domain_parameters(resource_id, gateway_payload.domain_response)
                {
                    let _ = self.tunnel.callbacks().on_error(&e);
                }
            }
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn add_resource(&self, resource_description: ResourceDescription) {
        if let Err(e) = self.tunnel.add_resource(resource_description) {
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
        let mut control_signaler = self.phoenix_channel.clone();
        tokio::spawn(async move {
            let err = match tunnel
                .request_connection(resource_id, gateway_id, relays, reference)
                .await
            {
                Ok(Request::NewConnection(connection_request)) => {
                    if let Err(err) = control_signaler
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
            Messages::Connect(connect) => self.connect(connect),
            Messages::ResourceAdded(resource) => self.add_resource(resource),
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
                    }
                });
            }
        }
        Ok(())
    }

    // Errors here means we need to disconnect
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn handle_error(
        &mut self,
        reply_error: ErrorReply,
        reference: Option<Reference>,
        topic: String,
    ) -> Result<()> {
        match (reply_error.error, reference) {
            (ErrorInfo::Offline, Some(reference)) => {
                let Ok(resource_id) = reference.parse::<ResourceId>() else {
                    tracing::error!(
                        "An offline error came back with a reference to a non-valid resource id"
                    );
                    let _ = self
                        .tunnel
                        .callbacks()
                        .on_error(&Error::ControlProtocolError);
                    return Ok(());
                };
                // TODO: Rate limit the number of attempts of getting the relays before just trying a local network connection
                self.tunnel.cleanup_connection(resource_id);
            }
            (ErrorInfo::Reason(Reason::Known(KnownError::UnmatchedTopic)), _) => {
                if let Err(e) = self.phoenix_channel.get_sender().join_topic(topic).await {
                    tracing::debug!(err = ?e, "couldn't join topic: {e:#?}");
                }
            }
            (ErrorInfo::Reason(Reason::Known(KnownError::TokenExpired)), _) => {
                return Err(Error::TokenExpired);
            }
            _ => {}
        }
        Ok(())
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

    pub async fn handle_tunnel_event(&mut self, event: Result<firezone_tunnel::Event<GatewayId>>) {
        match event {
            Ok(firezone_tunnel::Event::SignalIceCandidate { conn_id, candidate }) => {
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
            Ok(firezone_tunnel::Event::ConnectionIntent {
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
            Ok(firezone_tunnel::Event::DnsQuery(query)) => {
                // Until we handle it better on a gateway-like eventloop, making sure not to block the loop
                let Some(resolver) = self.fallback_resolver.lock().clone() else {
                    return;
                };
                let tunnel = self.tunnel.clone();
                tokio::spawn(async move {
                    let response = resolver.lookup(&query.name, query.record_type).await;
                    if let Err(err) = tunnel.write_dns_lookup_response(response, query.query) {
                        tracing::error!(err = ?err, name = query.name, record_type = ?query.record_type, "DNS lookup failed: {err:#}");
                    }
                });
            }
            Err(e) => {
                tracing::error!("Tunnel failed: {e}");
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
