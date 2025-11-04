#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    collections::{HashMap, hash_map},
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use rustls::ClientConfig;
use socket_factory::{SocketFactory, TcpSocket, TcpStream};
use tokio::task::JoinSet;
use tokio_rustls::TlsConnector;

pub struct HttpClient {
    sf: Arc<dyn SocketFactory<TcpSocket>>,

    client_tls_config: Arc<rustls::ClientConfig>,
    clients: HashMap<String, hyper::client::conn::http2::SendRequest<Full<Bytes>>>,
    connections: JoinSet<()>,

    dns_records: HashMap<String, Vec<IpAddr>>,
}

impl Default for HttpClient {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpClient {
    pub fn new() -> Self {
        // TODO: Use `rustls-platform-verifier` instead.
        let mut root_cert_store = rustls::RootCertStore::empty();
        root_cert_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

        let mut config = rustls::ClientConfig::builder()
            .with_root_certificates(root_cert_store)
            .with_no_client_auth();
        config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec(), b"http/1.0".to_vec()];

        Self {
            sf: Arc::new(socket_factory::tcp),
            clients: HashMap::default(),
            dns_records: HashMap::default(),
            connections: JoinSet::new(),
            client_tls_config: Arc::new(config),
        }
    }

    pub fn set_socket_factory(&mut self, sf: impl SocketFactory<TcpSocket>) {
        self.sf = Arc::new(sf);

        self.clients.clear();
        self.connections.abort_all();
    }

    pub fn set_dns_records(&mut self, domain: String, addresses: Vec<IpAddr>) {
        self.dns_records.insert(domain, addresses);
    }

    pub async fn send_request(
        &mut self,
        request: http::Request<Bytes>,
    ) -> Result<http::Response<Bytes>> {
        let host = request
            .uri()
            .host()
            .context("Missing host in request URI")?
            .to_owned();
        let scheme = request
            .uri()
            .scheme_str()
            .context("Missing scheme in request URI")?;
        let port = match scheme {
            "http" => request.uri().port_u16().unwrap_or(80),
            "https" => request.uri().port_u16().unwrap_or(443),
            other => bail!("Unsupported scheme '{other}'"),
        };

        let mut client = match self.clients.entry(host.clone()) {
            hash_map::Entry::Occupied(o) if !o.get().is_closed() => o.remove(), // We remove the Client such that it is discarded on any error.
            hash_map::Entry::Occupied(_) | hash_map::Entry::Vacant(_) => {
                let addresses = self
                    .dns_records
                    .get(&host)
                    .with_context(|| format!("No DNS records for '{host}'"))?
                    .clone();

                let (client, conn) = connect(
                    addresses,
                    port,
                    host.clone(),
                    self.client_tls_config.clone(),
                    self.sf.clone(),
                )
                .await?;

                self.connections.spawn({
                    let host = host.clone();

                    async move {
                        match conn.await.context("HTTP2 connection failed") {
                            Ok(()) => tracing::debug!(%host ,"HTTP2 connection finished"),
                            Err(e) => tracing::debug!(%host ,"{e:#}"),
                        }
                    }
                });

                client
            }
        };

        client
            .ready()
            .await
            .context("Failed to await readiness of HTTP2 client")?;

        let (parts, body) = request.into_parts();
        let request = http::Request::from_parts(parts, Full::new(body));

        let response = client
            .send_request(request)
            .await
            .context("Failed to send HTTP request")?;

        let (parts, incoming) = response.into_parts();

        let body = incoming
            .collect()
            .await
            .context("Failed to receive HTTP response body")?;

        self.clients.insert(host.clone(), client);

        Ok(http::Response::from_parts(parts, body.to_bytes()))
    }
}

async fn connect(
    addresses: Vec<IpAddr>,
    port: u16,
    domain: String,
    tls_config: Arc<ClientConfig>,
    sf: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<(
    hyper::client::conn::http2::SendRequest<Full<Bytes>>,
    hyper::client::conn::http2::Connection<
        hyper_util::rt::TokioIo<tokio_rustls::client::TlsStream<TcpStream>>,
        Full<Bytes>,
        hyper_util::rt::TokioExecutor,
    >,
)> {
    tracing::debug!(?addresses, %domain, "Creating new HTTP2 connection");

    for address in addresses {
        let socket = SocketAddr::new(address, port);

        match connect_one(socket, domain.clone(), tls_config.clone(), sf.clone()).await {
            Ok((client, conn)) => {
                tracing::debug!(%socket, %domain, "Created new HTTP2 connection");

                return Ok((client, conn));
            }
            Err(e) => {
                tracing::debug!(%socket, %domain, "Failed to create HTTP2 client: {e:#}");
                continue;
            }
        }
    }

    anyhow::bail!("Failed to connect to '{domain}'");
}

async fn connect_one(
    socket: SocketAddr,
    domain: String,
    tls_client_config: Arc<ClientConfig>,
    sf: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<(
    hyper::client::conn::http2::SendRequest<Full<Bytes>>,
    hyper::client::conn::http2::Connection<
        hyper_util::rt::TokioIo<tokio_rustls::client::TlsStream<TcpStream>>,
        Full<Bytes>,
        hyper_util::rt::TokioExecutor,
    >,
)> {
    let stream = sf
        .bind(socket)
        .context("Failed to create TCP socket")?
        .connect(socket)
        .await
        .context("Failed to connect TCP stream")?;

    let connector = TlsConnector::from(tls_client_config.clone());
    let tls_domain = rustls_pki_types::ServerName::try_from(domain)?;

    let stream = connector.connect(tls_domain, stream).await?;

    let mut builder =
        hyper::client::conn::http2::Builder::new(hyper_util::rt::TokioExecutor::new());
    builder.timer(hyper_util::rt::TokioTimer::default());
    builder.keep_alive_timeout(Duration::from_secs(1));
    builder.keep_alive_while_idle(true);
    builder.keep_alive_interval(Some(Duration::from_secs(5)));

    let (client, connection) = builder
        .handshake(hyper_util::rt::TokioIo::new(stream))
        .await
        .context("Failed to handshake HTTP2 connection")?;

    Ok((client, connection))
}

#[cfg(test)]
mod tests {
    use std::net::IpAddr;

    use super::*;

    #[tokio::test]
    #[ignore = "Requires Internet"]
    async fn doh_query() {
        rustls::crypto::ring::default_provider()
            .install_default()
            .unwrap();

        let mut http_client = HttpClient::new();
        http_client.set_dns_records(
            "one.one.one.one".to_owned(),
            vec![IpAddr::from([1, 1, 1, 1])],
        );

        let query = http::Request::builder()
            .uri("https://one.one.one.one/dns-query?name=example.com")
            .method("GET")
            .header("Accept", "application/dns-json")
            .body(Bytes::new())
            .unwrap();

        let response = http_client.send_request(query).await.unwrap();

        assert!(response.status().is_success());
    }
}
