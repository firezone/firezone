#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use anyhow::{Context, Result};
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use rustls::ClientConfig;
use socket_factory::{SocketFactory, TcpSocket, TcpStream};
use tokio_rustls::TlsConnector;
use tokio_util::task::AbortOnDropHandle;

type Client = hyper::client::conn::http2::SendRequest<Full<Bytes>>;
type Connection = hyper::client::conn::http2::Connection<
    hyper_util::rt::TokioIo<tokio_rustls::client::TlsStream<TcpStream>>,
    Full<Bytes>,
    hyper_util::rt::TokioExecutor,
>;

/// A specialised HTTP2 client that plugs into our [`SocketFactory`] abstraction.
///
/// One instance of this client is tied to a given domain.
/// It maintains a TCP connection and can send multiple requests across it in parallel.
/// If the TCP connection fails, [`Closed`] is returned.
/// In that case, the client becomes permanently unusable and should be discarded.
#[derive(Clone)]
pub struct HttpClient {
    host: String,
    client: Client,

    #[expect(dead_code, reason = "We only need to keep it around.")]
    connection: Arc<AbortOnDropHandle<()>>,
}

impl HttpClient {
    pub async fn new(
        host: String,
        addresses: Vec<IpAddr>,
        socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    ) -> Result<Self> {
        // TODO: Use `rustls-platform-verifier` instead.
        let mut root_cert_store = rustls::RootCertStore::empty();
        root_cert_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

        let mut config = rustls::ClientConfig::builder()
            .with_root_certificates(root_cert_store)
            .with_no_client_auth();
        config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec(), b"http/1.0".to_vec()];

        let (client, conn) = connect(
            addresses,
            443,
            host.clone(),
            Arc::new(config),
            socket_factory,
        )
        .await?;

        let connection = tokio::spawn({
            let host = host.clone();

            async move {
                match conn.await.context("HTTP2 connection failed") {
                    Ok(()) => tracing::debug!(%host, "HTTP2 connection finished"),
                    Err(e) => tracing::debug!(%host, "{e:#}"),
                }
            }
        });

        Ok(Self {
            host,
            client,
            connection: Arc::new(AbortOnDropHandle::new(connection)),
        })
    }

    pub fn send_request(
        &self,
        request: http::Request<Bytes>,
    ) -> Result<impl Future<Output = Result<http::Response<Bytes>>> + use<>> {
        anyhow::ensure!(!self.client.is_closed(), Closed);
        anyhow::ensure!(
            request.uri().port_u16().is_none_or(|p| p == 443),
            "Only supports requests to port 443"
        );

        let host = request
            .uri()
            .host()
            .context("Missing host in request URI")?
            .to_owned();
        anyhow::ensure!(
            host == self.host,
            "Can only send HTTP requests to host {}",
            self.host
        );

        let mut client = self.client.clone();

        Ok(async move {
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

            Ok(http::Response::from_parts(parts, body.to_bytes()))
        })
    }
}

#[derive(thiserror::Error, Debug)]
#[error("The connection is closed")]
pub struct Closed;

async fn connect(
    addresses: Vec<IpAddr>,
    port: u16,
    domain: String,
    tls_config: Arc<ClientConfig>,
    sf: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<(Client, Connection)> {
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

    anyhow::bail!("Failed to connect to '{domain}' on port {port}");
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
    async fn parallel_doh_queries() {
        rustls::crypto::ring::default_provider()
            .install_default()
            .unwrap();

        let http_client = HttpClient::new(
            "one.one.one.one".to_owned(),
            vec![IpAddr::from([1, 1, 1, 1])],
            Arc::new(socket_factory::tcp),
        )
        .await
        .unwrap();

        let query = http::Request::builder()
            .uri("https://one.one.one.one/dns-query?name=example.com")
            .method("GET")
            .header("Accept", "application/dns-json")
            .body(Bytes::new())
            .unwrap();

        let response1 = http_client.send_request(query.clone()).unwrap();
        let response2 = http_client.send_request(query.clone()).unwrap();

        let (response1, response2) = futures::future::try_join(response1, response2)
            .await
            .unwrap();

        assert!(response1.status().is_success());
        assert!(response2.status().is_success());
    }
}
