use std::{
    net::{IpAddr, ToSocketAddrs as _},
    sync::{Arc, LazyLock},
};

use anyhow::{Context as _, ErrorExt as _, Result};
use bootstrap_dns_client::BootstrapDnsClient;
use bytes::Bytes;
use http::{Request, Response};
use http_client::HttpClient;
use parking_lot::Mutex;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use tokio::runtime::Runtime;

type SocketFactories = (
    Arc<dyn SocketFactory<TcpSocket>>,
    Arc<dyn SocketFactory<UdpSocket>>,
);

/// Runtime hosting all ingest connections and the feature-flag re-eval timer.
pub(crate) static RUNTIME: LazyLock<Runtime> = LazyLock::new(init_runtime);

/// Socket factories and upstream resolvers shared by all ingest hosts.
///
/// connlib processes configure tunnel-bypassing factories so telemetry never
/// loops back through connlib; the resolvers are the system's upstream DNS
/// servers (never the system resolver itself, which may be connlib).
static SOCKETS: LazyLock<Mutex<Option<SocketFactories>>> = LazyLock::new(|| Mutex::new(None));

/// The resolvers used to look up all ingest hosts while a connlib session is
/// active.
///
/// These are the system's upstream DNS servers that connlib captured (never the
/// system resolver itself, which connlib has hijacked). We deliberately don't use
/// the portal-configured `upstream_do53`/`upstream_doh` here; honouring those for
/// telemetry is left to a future change.
///
/// - `Some(servers)`: a session is active and has hijacked the system resolver,
///   so we resolve via these captured servers directly. If the list is empty,
///   resolution fails and telemetry is effectively disabled until servers arrive;
///   we never fall back to the system resolver, which would loop back through
///   connlib.
/// - `None`: no session is active, so the system resolver is the real OS
///   resolver. We resolve ingest hosts via `getaddrinfo` directly.
static SERVERS: LazyLock<Mutex<Option<Vec<IpAddr>>>> = LazyLock::new(|| Mutex::new(None));

/// Configures the socket factories used to reach all ingest hosts.
pub(crate) fn configure(
    tcp: Arc<dyn SocketFactory<TcpSocket>>,
    udp: Arc<dyn SocketFactory<UdpSocket>>,
) {
    *SOCKETS.lock() = Some((tcp, udp));
}

/// Sets the upstream resolvers used while a connlib session is active.
pub(crate) fn set_system_resolvers(servers: Vec<IpAddr>) {
    *SERVERS.lock() = Some(servers);
}

/// Clears the upstream resolvers when no connlib session is active, so ingest
/// hosts are resolved via the default system resolver.
pub(crate) fn clear_system_resolvers() {
    *SERVERS.lock() = None;
}

/// Resets the shared socket factories so the next connection rebinds.
pub(crate) fn reset_sockets() {
    let sockets = SOCKETS.lock().clone();
    if let Some((tcp, udp)) = sockets {
        tcp.reset();
        udp.reset();
    }
}

/// A self-healing HTTP/2 client for a single ingest host.
///
/// While a connlib session is active, the host is resolved via
/// [`BootstrapDnsClient`] against the configured upstreams; otherwise it is
/// resolved via the default system resolver. Either way the connection goes
/// through the shared, tunnel-bypassing socket factories and is re-established
/// on demand when it is closed.
pub(crate) struct Client {
    host: &'static str,
    connection: Mutex<Option<HttpClient>>,
    /// Serialises bootstrapping so concurrent senders share a single connection.
    bootstrap: tokio::sync::Mutex<()>,
}

impl Client {
    pub(crate) fn new(host: &'static str) -> Self {
        Self {
            host,
            connection: Mutex::new(None),
            bootstrap: tokio::sync::Mutex::new(()),
        }
    }

    /// Drops the current connection so the next request reconnects.
    pub(crate) fn reset(&self) {
        *self.connection.lock() = None;
    }

    /// Sends an HTTP request over a (re-)established connection to the host.
    pub(crate) async fn send_request(&self, request: Request<Bytes>) -> Result<Response<Bytes>> {
        let connection = self.connection().await?;

        let response = match connection.send_request(request) {
            Ok(response) => response.await,
            Err(e) => Err(e),
        };

        // A closed connection means the path is broken; discard it so the next
        // request re-resolves and reconnects.
        if response
            .as_ref()
            .is_err_and(|e| e.any_is::<http_client::Closed>())
        {
            *self.connection.lock() = None;
        }

        response
    }

    async fn connection(&self) -> Result<HttpClient> {
        if let Some(connection) = self.live_connection() {
            return Ok(connection);
        }

        let _guard = self.bootstrap.lock().await;

        if let Some(connection) = self.live_connection() {
            return Ok(connection);
        }

        let connection = self.bootstrap().await?;
        *self.connection.lock() = Some(connection.clone());

        Ok(connection)
    }

    fn live_connection(&self) -> Option<HttpClient> {
        self.connection
            .lock()
            .as_ref()
            .filter(|connection| !connection.is_closed())
            .cloned()
    }

    async fn bootstrap(&self) -> Result<HttpClient> {
        let host = self.host;
        let (tcp, udp) = SOCKETS
            .lock()
            .clone()
            .context("Ingest client has no socket factories configured")?;
        let servers = SERVERS.lock().clone();

        // Anchor the connection task on our own runtime so it outlives the caller,
        // which may be a short-lived `block_on` on another runtime.
        RUNTIME
            .spawn(async move {
                let addresses = match servers {
                    // A connlib session is active and has hijacked the system
                    // resolver. Resolve via the upstreams directly, never the system
                    // resolver, which would loop back through connlib. With no
                    // upstreams we cannot resolve at all and telemetry is disabled
                    // until they arrive; don't fall back.
                    Some(servers) => {
                        anyhow::ensure!(
                            !servers.is_empty(),
                            "No upstream resolvers configured for ingest host {host}; \
                             telemetry is disabled while the session is active"
                        );

                        BootstrapDnsClient::new(udp, tcp.clone(), servers)
                            .resolve(host)
                            .await
                            .with_context(|| format!("Failed to resolve ingest host {host}"))?
                    }
                    // No session is active, so the system resolver is the real OS
                    // resolver. Resolve via `getaddrinfo` directly.
                    None => resolve_via_system(host).await?,
                };

                anyhow::ensure!(!addresses.is_empty(), "No addresses for ingest host {host}");

                HttpClient::new(host.to_owned(), addresses, tcp)
                    .await
                    .context("Failed to connect to ingest host")
            })
            .await
            .context("Bootstrap task failed")?
    }
}

/// Resolves a host via the default system resolver (`getaddrinfo`).
///
/// Only safe when no connlib session is active; otherwise the lookup would route
/// through connlib's stub resolver and loop back into the tunnel.
async fn resolve_via_system(host: &'static str) -> Result<Vec<IpAddr>> {
    tokio::task::spawn_blocking(move || {
        let addresses = (host, 443u16)
            .to_socket_addrs()
            .with_context(|| format!("Failed to resolve ingest host {host} via system resolver"))?
            .map(|addr| addr.ip())
            .collect::<Vec<_>>();

        Ok(addresses)
    })
    .await
    .context("System resolver task panicked")?
}

fn init_runtime() -> Runtime {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1) // We only need 1 worker thread.
        .thread_name("ingest-worker")
        .enable_io()
        .enable_time()
        .build()
        .expect("to be able to build runtime");

    runtime.spawn(crate::feature_flags::reeval_timer());

    runtime
}
