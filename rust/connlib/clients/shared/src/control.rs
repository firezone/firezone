use async_compression::tokio::bufread::GzipEncoder;
use bimap::BiMap;
use connlib_shared::control::{ChannelError, ErrorReply};
use connlib_shared::messages::{DnsServer, GatewayResponse, IpDnsServer};
use connlib_shared::IpProvider;
use firezone_tunnel::ClientTunnel;
use ip_network::IpNetwork;
use std::io;
use std::net::IpAddr;
use std::path::PathBuf;
use std::str::FromStr;

use crate::messages::{
    BroadcastGatewayIceCandidates, Connect, ConnectionDetails, EgressMessages,
    GatewayIceCandidates, InitClient, Messages,
};
use connlib_shared::{
    control::{PhoenixSenderWithTopic, Reference},
    messages::{GatewayId, ResourceDescription, ResourceId},
    Callbacks,
    Error::{self},
    Result,
};

use firezone_tunnel::Request;
use reqwest::header::{CONTENT_ENCODING, CONTENT_TYPE};
use std::collections::HashMap;
use tokio::io::BufReader;
use tokio_util::codec::{BytesCodec, FramedRead};
use url::Url;

const DNS_PORT: u16 = 53;
const DNS_SENTINELS_V4: &str = "100.100.111.0/24";
const DNS_SENTINELS_V6: &str = "fd00:2021:1111:8000:100:100:111:0/120";

pub struct ControlPlane<CB: Callbacks> {
    pub tunnel: ClientTunnel<CB>,
    pub phoenix_channel: PhoenixSenderWithTopic,
    pub tunnel_init: bool,

    pub next_request_id: usize,
    pub sent_connection_intents: SentConnectionIntents,
}

#[derive(Default)]
pub struct SentConnectionIntents {
    inner: HashMap<usize, ResourceId>,
}

impl SentConnectionIntents {
    fn register_new_intent(&mut self, id: usize, resource: ResourceId) {
        self.inner.insert(id, resource);
    }

    /// To be called when we receive the connection details for a particular resource.
    ///
    /// Returns whether we should accept them.
    fn handle_connection_details_received(&mut self, reference: usize, r: ResourceId) -> bool {
        let has_more_recent_intent = self
            .inner
            .iter()
            .any(|(req, resource)| req > &reference && resource == &r);

        if has_more_recent_intent {
            return false;
        }

        debug_assert!(self
            .inner
            .get(&reference)
            .is_some_and(|resource| resource == &r));
        self.inner.retain(|_, v| v != &r);

        true
    }

    fn handle_error(&mut self, reference: usize) -> Option<ResourceId> {
        self.inner.remove(&reference)
    }
}

fn effective_dns_servers(
    upstream_dns: Vec<DnsServer>,
    default_resolvers: Vec<IpAddr>,
) -> Vec<DnsServer> {
    if !upstream_dns.is_empty() {
        return upstream_dns;
    }

    let mut dns_servers = default_resolvers
        .into_iter()
        .filter(|ip| !IpNetwork::from_str(DNS_SENTINELS_V4).unwrap().contains(*ip))
        .filter(|ip| !IpNetwork::from_str(DNS_SENTINELS_V6).unwrap().contains(*ip))
        .peekable();

    if dns_servers.peek().is_none() {
        tracing::error!("No system default DNS servers available! Can't initialize resolver. DNS will be broken.");
        return Vec::new();
    }

    dns_servers
        .map(|ip| {
            DnsServer::IpPort(IpDnsServer {
                address: (ip, DNS_PORT).into(),
            })
        })
        .collect()
}

fn sentinel_dns_mapping(dns: &[DnsServer]) -> BiMap<IpAddr, DnsServer> {
    let mut ip_provider = IpProvider::new(
        DNS_SENTINELS_V4.parse().unwrap(),
        DNS_SENTINELS_V6.parse().unwrap(),
    );

    dns.iter()
        .cloned()
        .map(|i| {
            (
                ip_provider
                    .get_proxy_ip_for(&i.ip())
                    .expect("We only support up to 256 IpV4 DNS servers and 256 IpV6 DNS servers"),
                i,
            )
        })
        .collect()
}

impl<CB: Callbacks + 'static> ControlPlane<CB> {
    async fn init(
        &mut self,
        InitClient {
            interface,
            resources,
        }: InitClient,
    ) -> Result<()> {
        let effective_dns_servers = effective_dns_servers(
            interface.upstream_dns.clone(),
            self.tunnel
                .callbacks()
                .get_system_default_resolvers()
                .ok()
                .flatten()
                .unwrap_or_default(),
        );

        let sentinel_mapping = sentinel_dns_mapping(&effective_dns_servers);

        if !self.tunnel_init {
            if let Err(e) = self
                .tunnel
                .set_interface(&interface, sentinel_mapping.clone())
            {
                tracing::error!(error = ?e, "Error initializing interface");
                return Err(e);
            } else {
                self.tunnel_init = true;
                tracing::info!("Firezone Started!");
            }

            for resource_description in resources {
                self.add_resource(resource_description);
            }
        } else {
            tracing::info!("Firezone reinitializated");
        }
        Ok(())
    }

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
                    tracing::debug!(error = ?e, "Error accepting connection: {e:#?}");
                }
            }
            GatewayResponse::ResourceAccepted(gateway_payload) => {
                if let Err(e) = self
                    .tunnel
                    .received_domain_parameters(resource_id, gateway_payload.domain_response)
                {
                    tracing::debug!(error = ?e, "Error accepting resource: {e:#?}");
                }
            }
        }
    }

    pub fn add_resource(&mut self, resource_description: ResourceDescription) {
        if let Err(e) = self.tunnel.add_resource(resource_description) {
            tracing::error!(message = "Can't add resource", error = ?e);
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn resource_deleted(&mut self, id: ResourceId) {
        self.tunnel.remove_resource(id);
    }

    fn connection_details(
        &mut self,
        ConnectionDetails {
            gateway_id,
            resource_id,
            relays,
            ..
        }: ConnectionDetails,
        reference: Option<Reference>,
    ) {
        let Some(reference) = reference.as_ref().and_then(|r| r.parse::<usize>().ok()) else {
            tracing::warn!(?reference, "Failed to parse reference as usize");
            return;
        };

        if !self
            .sent_connection_intents
            .handle_connection_details_received(reference, resource_id)
        {
            tracing::debug!("Discarding stale connection details");

            return;
        }

        let mut control_signaler = self.phoenix_channel.clone();

        let err = match self
            .tunnel
            .request_connection(resource_id, gateway_id, relays)
        {
            Ok(Request::NewConnection(connection_request)) => {
                tokio::spawn(async move {
                    // TODO: create a reference number and keep track for the response
                    // Note: We used to clean up connections here upon failures with the _channel_ to the underlying portal connection.
                    // This is deemed unnecessary during the migration period to `phoenix-channel` because it means that the receiver is deallocated at which point we are probably shutting down?
                    let _ = control_signaler
                        .send_with_ref(
                            EgressMessages::RequestConnection(connection_request),
                            resource_id,
                        )
                        .await;
                });
                return;
            }
            Ok(Request::ReuseConnection(connection_request)) => {
                tokio::spawn(async move {
                    // TODO: create a reference number and keep track for the response
                    // Note: We used to clean up connections here upon failures with the _channel_ to the underlying portal connection.
                    // This is deemed unnecessary during the migration period to `phoenix-channel` because it means that the receiver is deallocated at which point we are probably shutting down?
                    let _ = control_signaler
                        .send_with_ref(
                            EgressMessages::ReuseConnection(connection_request),
                            resource_id,
                        )
                        .await;
                });
                return;
            }
            Err(err) => err,
        };

        self.tunnel.cleanup_connection(resource_id);
        tracing::error!("Error request connection details: {err}");
    }

    #[tracing::instrument(level = "trace", skip_all, fields(gateway = %gateway_id))]
    fn add_ice_candidate(
        &mut self,
        GatewayIceCandidates {
            gateway_id,
            candidates,
        }: GatewayIceCandidates,
    ) {
        for candidate in candidates {
            self.tunnel.add_ice_candidate(gateway_id, candidate)
        }
    }

    #[tracing::instrument(level = "trace", skip(self, msg))]
    pub async fn handle_message(
        &mut self,
        msg: Messages,
        reference: Option<Reference>,
    ) -> Result<()> {
        match msg {
            Messages::Init(init) => self.init(init).await?,
            Messages::ConfigChanged(_update) => {
                tracing::info!("Runtime config updates not yet implemented");
            }
            Messages::ConnectionDetails(connection_details) => {
                self.connection_details(connection_details, reference)
            }
            Messages::Connect(connect) => self.connect(connect),
            Messages::ResourceCreatedOrUpdated(resource) => self.add_resource(resource),
            Messages::ResourceDeleted(resource) => self.resource_deleted(resource.0),
            Messages::IceCandidates(ice_candidate) => self.add_ice_candidate(ice_candidate),
            Messages::SignedLogUrl(url) => {
                let Some(path) = self.tunnel.callbacks().roll_log_file() else {
                    return Ok(());
                };

                tokio::spawn(async move {
                    if let Err(e) = upload(path.clone(), url).await {
                        tracing::warn!(
                            "Failed to upload log file at path {path_display}: {e}. Not retrying.",
                            path_display = path.display()
                        );
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
        reply_error: ChannelError,
        reference: Option<Reference>,
        topic: String,
    ) -> Result<()> {
        match (reply_error, reference) {
            (ChannelError::ErrorReply(ErrorReply::Offline), Some(reference)) => {
                let Ok(request_id) = reference.parse::<usize>() else {
                    return Ok(());
                };

                let Some(resource) = self.sent_connection_intents.handle_error(request_id) else {
                    return Ok(());
                };

                tracing::debug!(%resource, "Resource is offline");

                self.tunnel.cleanup_connection(resource);
            }
            (ChannelError::ErrorReply(ErrorReply::UnmatchedTopic), _) => {
                if let Err(e) = self.phoenix_channel.get_sender().join_topic(topic).await {
                    tracing::debug!(err = ?e, "couldn't join topic: {e:#?}");
                }
            }
            (ChannelError::ErrorReply(ErrorReply::TokenExpired), _)
            | (ChannelError::ErrorMsg(Error::ClosedByPortal), _) => {
                return Err(Error::ClosedByPortal);
            }
            _ => {}
        }
        Ok(())
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
            }) => {
                let id = self.next_request_id;
                self.next_request_id += 1;
                self.sent_connection_intents
                    .register_new_intent(id, resource);

                if let Err(e) = self
                    .phoenix_channel
                    .clone()
                    .send_with_ref(
                        EgressMessages::PrepareConnection {
                            resource_id: resource,
                            connected_gateway_ids,
                        },
                        id,
                    )
                    .await
                {
                    tracing::error!("Failed to prepare connection: {e}");

                    // TODO: Clean up connection in `ClientState` here?
                }
            }
            Ok(firezone_tunnel::Event::RefreshResources { connections }) => {
                let mut control_signaler = self.phoenix_channel.clone();
                tokio::spawn(async move {
                    for connection in connections {
                        let resource_id = connection.resource_id;
                        if let Err(err) = control_signaler
                            .send_with_ref(EgressMessages::ReuseConnection(connection), resource_id)
                            .await
                        {
                            tracing::warn!(%resource_id, ?err, "failed to refresh resource dns: {err:#?}");
                        }
                    }
                });
            }
            Ok(firezone_tunnel::Event::StopPeer(_)) => {
                // This should never bubbled up
                // TODO: we might want to segregate events further
            }
            Ok(firezone_tunnel::Event::SendPacket(_)) => {
                unimplemented!("Handled internally");
            }
            Err(e) => {
                tracing::error!("Tunnel failed: {e:#?}");
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discards_old_connection_intent() {
        let mut intents = SentConnectionIntents::default();

        let resource = ResourceId::random();

        intents.register_new_intent(1, resource);
        intents.register_new_intent(2, resource);

        let should_accept = intents.handle_connection_details_received(1, resource);

        assert!(!should_accept);
    }

    #[test]
    fn allows_unrelated_intents() {
        let mut intents = SentConnectionIntents::default();

        let resource1 = ResourceId::random();
        let resource2 = ResourceId::random();

        intents.register_new_intent(1, resource1);
        intents.register_new_intent(2, resource2);

        let should_accept_1 = intents.handle_connection_details_received(1, resource1);
        let should_accept_2 = intents.handle_connection_details_received(2, resource2);

        assert!(should_accept_1);
        assert!(should_accept_2);
    }
}
