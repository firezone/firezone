#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    net::{IpAddr, SocketAddr},
    pin::Pin,
    sync::{Arc, LazyLock},
    time::Duration,
};

use anyhow::{Context, Result};
use bytes::Bytes;
use futures::{StreamExt as _, stream::FuturesUnordered};
use http_body_util::{BodyExt, Full};
use rustls::{ClientConfig, RootCertStore};
use socket_factory::{SocketFactory, TcpSocket};
use tokio_rustls::TlsConnector;
use tokio_util::task::AbortOnDropHandle;

/// The negotiated request sender for a connection.
///
/// HTTP/2 multiplexes, so its sender is cheaply cloned and used concurrently.
/// HTTP/1.1 serialises one request at a time, so it is shared behind a mutex; the
/// `Clone` on [`HttpClient`] (which telemetry's parallel DoH path relies on) still
/// holds, but concurrent sends over an h1 connection take turns.
#[derive(Clone)]
enum Sender {
    H2(hyper::client::conn::http2::SendRequest<Full<Bytes>>),
    H1(Arc<tokio::sync::Mutex<hyper::client::conn::http1::SendRequest<Full<Bytes>>>>),
}

/// A future that drives a connection to completion. Boxed so the h2 and h1
/// connection types share one return shape.
type ConnectionDriver = Pin<Box<dyn Future<Output = ()> + Send>>;

/// The TLS configuration of an [`HttpClient`] connection.
#[derive(Clone)]
pub struct TlsConfig(Arc<ClientConfig>);

impl TlsConfig {
    /// Returns the configuration that trusts the roots bundled via `webpki-roots`.
    ///
    /// It is built on first use and shared by all callers.
    pub fn webpki_roots() -> Self {
        // TODO: Use `rustls-platform-verifier` instead.
        static CONFIG: LazyLock<TlsConfig> = LazyLock::new(|| {
            TlsConfig::new(RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
            })
        });

        CONFIG.clone()
    }

    /// Builds a configuration that trusts `roots`.
    pub fn new(roots: RootCertStore) -> Self {
        // An explicit provider cannot panic for lack of a process-default one.
        let mut config =
            ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .expect("ring supports the default protocol versions")
                .with_root_certificates(roots)
                .with_no_client_auth();
        config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

        Self(Arc::new(config))
    }
}

/// An HTTP client that plugs into our [`SocketFactory`] abstraction.
///
/// One instance is tied to a given host and port. It negotiates HTTP/2 if the server
/// supports it (ALPN `h2`) and falls back to HTTP/1.1 otherwise. The connection is
/// maintained for the client's lifetime; once it fails, every request errors with
/// [`Closed`] and the client should be discarded.
#[derive(Clone)]
pub struct HttpClient {
    host: String,
    port: u16,
    sender: Sender,

    #[expect(dead_code, reason = "We only need to keep it around.")]
    connection: Arc<AbortOnDropHandle<()>>,
}

impl HttpClient {
    /// Connects to `host` on `port` via the first of `addresses` that succeeds.
    ///
    /// `host` is spelled as in a URI, i.e. an IPv6 address is enclosed in brackets.
    pub async fn new(
        host: String,
        port: u16,
        addresses: Vec<IpAddr>,
        tls_config: TlsConfig,
        socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    ) -> Result<Self> {
        let (sender, driver) =
            connect(addresses, port, host.clone(), tls_config.0, socket_factory).await?;

        let connection = tokio::spawn({
            let host = host.clone();

            async move {
                driver.await;
                tracing::debug!(%host, "HTTP connection finished");
            }
        });

        Ok(Self {
            host,
            port,
            sender,
            connection: Arc::new(AbortOnDropHandle::new(connection)),
        })
    }

    /// Whether the underlying connection has been closed.
    ///
    /// A closed client is permanently unusable and should be discarded.
    pub fn is_closed(&self) -> bool {
        match &self.sender {
            Sender::H2(client) => client.is_closed(),
            // A held lock means a request is in flight, so the connection is still
            // active; an idle lock lets us ask the sender directly.
            Sender::H1(mutex) => mutex.try_lock().is_ok_and(|sender| sender.is_closed()),
        }
    }

    pub fn send_request(
        &self,
        request: http::Request<Bytes>,
    ) -> Result<impl Future<Output = Result<http::Response<Bytes>>> + use<>> {
        anyhow::ensure!(!self.is_closed(), Closed);

        let port = request.uri().port_u16().unwrap_or(443);
        anyhow::ensure!(
            port == self.port,
            "Can only send HTTP requests to port {}",
            self.port
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

        let authority = match port {
            443 => host,
            port => format!("{host}:{port}"),
        };

        let sender = self.sender.clone();

        Ok(async move {
            let (parts, body) = request.into_parts();
            let mut request = http::Request::from_parts(parts, Full::new(body));

            let response = match sender {
                Sender::H2(mut client) => {
                    client
                        .ready()
                        .await
                        .context("Failed to await readiness of HTTP/2 client")?;

                    client
                        .send_request(request)
                        .await
                        .context("Failed to send HTTP/2 request")
                        .context(Closed)?
                }
                Sender::H1(mutex) => {
                    // HTTP/1.1 carries the host in a `Host` header (HTTP/2 uses the
                    // `:authority` pseudo-header derived from the URI), so add it if
                    // the caller didn't.
                    if !request.headers().contains_key(http::header::HOST) {
                        let value = http::HeaderValue::from_str(&authority)
                            .context("Invalid host header")?;
                        request.headers_mut().insert(http::header::HOST, value);
                    }

                    let mut client = mutex.lock().await;
                    client
                        .ready()
                        .await
                        .context("Failed to await readiness of HTTP/1.1 client")?;

                    client
                        .send_request(request)
                        .await
                        .context("Failed to send HTTP/1.1 request")
                        .context(Closed)?
                }
            };

            let (parts, incoming) = response.into_parts();

            let body = incoming
                .collect()
                .await
                .context("Failed to receive HTTP response body")
                .context(Closed)?;

            Ok(http::Response::from_parts(parts, body.to_bytes()))
        })
    }
}

/// The connection behind an [`HttpClient`] is closed or has failed.
///
/// A transport error on a persistent connection leaves it dead or dying, so
/// every request that hits one carries this error, not only those sent after
/// [`HttpClient::is_closed`] starts reporting `true`.
#[derive(thiserror::Error, Debug)]
#[error("The connection is closed")]
pub struct Closed;

async fn connect(
    addresses: Vec<IpAddr>,
    port: u16,
    domain: String,
    tls_config: Arc<ClientConfig>,
    sf: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<(Sender, ConnectionDriver)> {
    tracing::debug!(?addresses, %domain, "Creating new HTTP connection");

    // Race the addresses instead of walking them in order. A blackholed address
    // fails only once the OS gives up on the TCP connect, over a minute later,
    // so in order a working address behind one is not reached until then.
    let mut attempts = addresses
        .into_iter()
        .map(|address| {
            let socket = SocketAddr::new(address, port);
            let domain = domain.clone();
            let tls_config = tls_config.clone();
            let sf = sf.clone();

            async move { (socket, connect_one(socket, domain, tls_config, sf).await) }
        })
        .collect::<FuturesUnordered<_>>();

    // Ends once every attempt has resolved. Returning early drops the losing
    // attempts, which cancels them.
    while let Some((socket, attempt)) = attempts.next().await {
        match attempt {
            Ok(connection) => {
                tracing::debug!(%socket, %domain, "Created new HTTP connection");

                return Ok(connection);
            }
            Err(e) => tracing::debug!(%socket, %domain, "Failed to create HTTP client: {e:#}"),
        }
    }

    anyhow::bail!("Failed to connect to '{domain}' on port {port}");
}

async fn connect_one(
    socket: SocketAddr,
    domain: String,
    tls_client_config: Arc<ClientConfig>,
    sf: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<(Sender, ConnectionDriver)> {
    let stream = sf
        .bind(socket)
        .context("Failed to create TCP socket")?
        .connect(socket)
        .await
        .context("Failed to connect TCP stream")?;

    let connector = TlsConnector::from(tls_client_config);
    // A URI encloses an IPv6 address in brackets, a `ServerName` does not.
    let tls_domain = rustls_pki_types::ServerName::try_from(
        domain.trim_start_matches('[').trim_end_matches(']'),
    )?
    .to_owned();

    let stream = connector.connect(tls_domain, stream).await?;

    // Drive the HTTP version off what the server negotiated via ALPN.
    let is_h2 = stream.get_ref().1.alpn_protocol() == Some(b"h2".as_slice());
    let io = hyper_util::rt::TokioIo::new(stream);

    if is_h2 {
        let mut builder =
            hyper::client::conn::http2::Builder::new(hyper_util::rt::TokioExecutor::new());
        builder.timer(hyper_util::rt::TokioTimer::default());
        builder.keep_alive_timeout(Duration::from_secs(1));
        builder.keep_alive_while_idle(true);
        builder.keep_alive_interval(Some(Duration::from_secs(5)));

        let (sender, conn) = builder
            .handshake::<_, Full<Bytes>>(io)
            .await
            .context("Failed to handshake HTTP/2 connection")?;

        let driver = Box::pin(async move {
            if let Err(e) = conn.await {
                tracing::debug!("HTTP/2 connection failed: {e:#}");
            }
        });

        Ok((Sender::H2(sender), driver))
    } else {
        let (sender, conn) = hyper::client::conn::http1::Builder::new()
            .handshake::<_, Full<Bytes>>(io)
            .await
            .context("Failed to handshake HTTP/1.1 connection")?;

        let driver = Box::pin(async move {
            if let Err(e) = conn.await {
                tracing::debug!("HTTP/1.1 connection failed: {e:#}");
            }
        });

        Ok((
            Sender::H1(Arc::new(tokio::sync::Mutex::new(sender))),
            driver,
        ))
    }
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr};

    use super::*;

    #[tokio::test]
    async fn parallel_doh_queries() {
        let server = doh_test_server::DohTestServer::spawn(Ipv4Addr::LOCALHOST)
            .await
            .unwrap();
        let http_client = HttpClient::new(
            "127.0.0.1".to_owned(),
            server.url().port(),
            vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
            TlsConfig::new(server.root_cert_store()),
            Arc::new(socket_factory::tcp),
        )
        .await
        .unwrap();

        let query = dns_types::Query::new("example.com".parse().unwrap(), dns_types::RecordType::A)
            .try_into_http_request(&server.url())
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
