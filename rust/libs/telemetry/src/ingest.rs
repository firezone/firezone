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

/// Socket factories shared by all ingest hosts.
///
/// connlib processes configure tunnel-bypassing factories so telemetry never
/// loops back through connlib.
static SOCKETS: LazyLock<Mutex<Option<SocketFactories>>> = LazyLock::new(|| Mutex::new(None));

/// How ingest hosts are currently resolved.
///
/// Defaults to the system resolver and is swapped for connlib's upstreams while a
/// session owns the system resolver (see [`SystemResolvers`]).
static RESOLVER: LazyLock<Mutex<IngestResolver>> =
    LazyLock::new(|| Mutex::new(IngestResolver::System(LibcDnsClient)));

/// Configures the socket factories used to reach all ingest hosts.
pub(crate) fn configure(
    tcp: Arc<dyn SocketFactory<TcpSocket>>,
    udp: Arc<dyn SocketFactory<UdpSocket>>,
) {
    *SOCKETS.lock() = Some((tcp, udp));
}

/// Routes telemetry ingest-host lookups through connlib's upstream resolvers while
/// a connlib session owns the system resolver.
///
/// connlib hijacks the system resolver for the lifetime of a session, so a plain
/// `getaddrinfo` would loop ingest lookups back through connlib's stub. While the
/// guard is held, lookups go through a [`BootstrapDnsClient`] against the captured
/// upstreams. Dropping it restores resolution via the system resolver, tying the
/// bypass to the session's lifetime.
#[must_use = "dropping the guard restores system-resolver lookups for ingest hosts"]
pub struct SystemResolvers {
    _private: (),
}

impl SystemResolvers {
    /// Captures `servers` as the ingest upstreams, bypassing the system resolver
    /// until the guard is dropped.
    pub fn capture(servers: Vec<IpAddr>) -> Self {
        set_resolver(upstream(servers));

        Self { _private: () }
    }

    /// Replaces the captured upstreams, e.g. when connlib learns updated resolvers.
    pub fn set(&self, servers: Vec<IpAddr>) {
        set_resolver(upstream(servers));
    }
}

impl Drop for SystemResolvers {
    fn drop(&mut self) {
        set_resolver(IngestResolver::System(LibcDnsClient));
    }
}

/// Swaps the active resolver and re-evaluates feature flags, which may have been
/// disabled while (working) resolvers were missing.
fn set_resolver(resolver: IngestResolver) {
    *RESOLVER.lock() = resolver;
    crate::feature_flags::reevaluate_current();
}

/// Builds an upstream resolver from `servers` and the configured socket factories.
fn upstream(servers: Vec<IpAddr>) -> IngestResolver {
    let Some((tcp, udp)) = SOCKETS.lock().clone() else {
        // `configure` runs before any session captures resolvers; without socket
        // factories telemetry cannot connect at all, so the resolver is moot.
        return IngestResolver::System(LibcDnsClient);
    };

    IngestResolver::Upstream(BootstrapDnsClient::new(udp, tcp, servers))
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
        let (tcp, _) = SOCKETS
            .lock()
            .clone()
            .context("Ingest client has no socket factories configured")?;
        let resolver = RESOLVER.lock().clone();

        // Anchor the connection task on our own runtime so it outlives the caller,
        // which may be a short-lived `block_on` on another runtime.
        RUNTIME
            .spawn(async move {
                let addresses = resolver.resolve(host).await?;

                anyhow::ensure!(!addresses.is_empty(), "No addresses for ingest host {host}");

                HttpClient::new(host.to_owned(), addresses, tcp)
                    .await
                    .context("Failed to connect to ingest host")
            })
            .await
            .context("Bootstrap task failed")?
    }
}

/// Resolves ingest hosts, either through connlib's upstreams or the system resolver.
#[derive(Clone)]
enum IngestResolver {
    /// A connlib session owns the system resolver, so resolve via the captured
    /// upstreams directly; `getaddrinfo` would loop back through connlib's stub.
    Upstream(BootstrapDnsClient),
    /// No session owns the system resolver, so resolve via libc (`getaddrinfo`).
    System(LibcDnsClient),
}

impl IngestResolver {
    async fn resolve(&self, host: &str) -> Result<Vec<IpAddr>> {
        match self {
            IngestResolver::Upstream(client) => client
                .resolve(host.to_owned())
                .await
                .with_context(|| format!("Failed to resolve ingest host {host}")),
            IngestResolver::System(client) => client.resolve(host).await,
        }
    }
}

/// Resolves an arbitrary ingest host through the active [`IngestResolver`], so the
/// flow-log uploader shares telemetry's session-aware resolution.
pub(crate) async fn resolve_host(host: &str) -> Result<Vec<IpAddr>> {
    let resolver = RESOLVER.lock().clone();
    let addresses = resolver.resolve(host).await?;
    anyhow::ensure!(!addresses.is_empty(), "No addresses for ingest host {host}");

    Ok(addresses)
}

/// Resolves host names via the system resolver, i.e. libc's `getaddrinfo`.
///
/// Only safe when no connlib session owns the system resolver; otherwise the lookup
/// would route through connlib's stub resolver and loop back into the tunnel.
#[derive(Clone, Copy)]
struct LibcDnsClient;

impl LibcDnsClient {
    async fn resolve(&self, host: &str) -> Result<Vec<IpAddr>> {
        let host = host.to_owned();

        tokio::task::spawn_blocking(move || {
            let addresses = (host.as_str(), 443u16)
                .to_socket_addrs()
                .with_context(|| {
                    format!("Failed to resolve ingest host {host} via system resolver")
                })?
                .map(|addr| addr.ip())
                .collect::<Vec<_>>();

            Ok(addresses)
        })
        .await
        .context("System resolver task panicked")?
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

#[cfg(test)]
mod tests {
    use super::*;

    // Exercises the shared `SOCKETS`/`RESOLVER` statics, so it stays a single test
    // to avoid racing against parallel test threads.
    #[test]
    fn capture_switches_to_upstream_and_drop_restores_system() {
        configure(Arc::new(socket_factory::tcp), Arc::new(socket_factory::udp));

        {
            let _guard = SystemResolvers::capture(vec![IpAddr::from([1, 1, 1, 1])]);
            assert!(matches!(*RESOLVER.lock(), IngestResolver::Upstream(_)));
        }

        assert!(matches!(*RESOLVER.lock(), IngestResolver::System(_)));
    }
}
