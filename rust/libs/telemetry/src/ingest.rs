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
static SERVERS: LazyLock<Mutex<Vec<IpAddr>>> = LazyLock::new(|| Mutex::new(Vec::new()));

/// Configures the socket factories used to reach all ingest hosts.
pub(crate) fn configure(
    tcp: Arc<dyn SocketFactory<TcpSocket>>,
    udp: Arc<dyn SocketFactory<UdpSocket>>,
) {
    *SOCKETS.lock() = Some((tcp, udp));
}

/// Updates the upstream resolvers used to look up all ingest hosts.
pub(crate) fn update_system_resolvers(servers: Vec<IpAddr>) {
    *SERVERS.lock() = servers;
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
/// The host is resolved via [`BootstrapDnsClient`] against the configured
/// upstreams and connected through the shared, tunnel-bypassing socket factories,
/// falling back to addresses seeded from the system resolver at startup. The
/// connection is re-established on demand when it is closed.
pub(crate) struct Client {
    host: &'static str,
    seed_addresses: Mutex<Vec<IpAddr>>,
    connection: Mutex<Option<HttpClient>>,
    /// Serialises bootstrapping so concurrent senders share a single connection.
    bootstrap: tokio::sync::Mutex<()>,
}

impl Client {
    pub(crate) fn new(host: &'static str) -> Self {
        Self {
            host,
            seed_addresses: Mutex::new(Vec::new()),
            connection: Mutex::new(None),
            bootstrap: tokio::sync::Mutex::new(()),
        }
    }

    /// Seeds the host addresses using the system resolver.
    ///
    /// Must run at startup, before connlib reconfigures the system resolver, so the
    /// lookup reaches the real upstream and not connlib itself. Used as a fallback
    /// until the bootstrap resolver has upstreams configured.
    pub(crate) fn init_addresses(&self) {
        let addresses = (self.host, 443u16)
            .to_socket_addrs()
            .inspect_err(|e| {
                tracing::debug!(host = %self.host, "Failed to seed ingest host addresses: {e:#}")
            })
            .map(|addresses| addresses.map(|addr| addr.ip()).collect::<Vec<_>>())
            .unwrap_or_default();

        tracing::debug!(host = %self.host, ?addresses, "Seeded ingest host addresses from system resolver");

        *self.seed_addresses.lock() = addresses;
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
        // Always serialise here: telemetry is low-volume, so this lock is
        // effectively uncontended and a double-checked fast path isn't worth it.
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
        let seed_addresses = self.seed_addresses.lock().clone();

        // Anchor the connection task on our own runtime so it outlives the caller,
        // which may be a short-lived `block_on` on another runtime.
        RUNTIME
            .spawn(async move {
                // Resolve via the bootstrap resolver, which never uses the system
                // resolver (i.e. connlib), and add the addresses seeded at startup as
                // extra fallback candidates. `HttpClient` tries them in order and
                // connects to the first that works.
                //
                // Skip the resolver while we have no upstreams yet (e.g. before
                // connlib reports the system DNS servers); the seed covers that.
                let mut addresses = if servers.is_empty() {
                    Vec::new()
                } else {
                    BootstrapDnsClient::new(udp, tcp.clone(), servers)
                        .resolve(host)
                        .await
                        .inspect_err(
                            |e| tracing::debug!(%host, "Failed to resolve ingest host: {e:#}"),
                        )
                        .unwrap_or_default()
                };

                for address in seed_addresses {
                    if !addresses.contains(&address) {
                        addresses.push(address);
                    }
                }

                anyhow::ensure!(!addresses.is_empty(), "No addresses for ingest host {host}");

                HttpClient::new(host.to_owned(), addresses, tcp)
                    .await
                    .context("Failed to connect to ingest host")
            })
            .await
            .context("Bootstrap task failed")?
    }
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
