use std::sync::{Arc, LazyLock};

use anyhow::{Context as _, ErrorExt as _, Result};
use bytes::Bytes;
use http::{Request, Response};
use http_client::HttpClient;
use parking_lot::Mutex;
use socket_factory::{SocketFactory, TcpSocket};
use tokio::runtime::Runtime;

/// Runtime hosting all ingest connections and the feature-flag re-eval timer.
pub(crate) static RUNTIME: LazyLock<Runtime> = LazyLock::new(init_runtime);

/// TCP socket factory shared by all ingest connections.
///
/// connlib processes configure a tunnel-bypassing factory so telemetry never
/// loops back through connlib.
static SOCKET_FACTORY: LazyLock<Mutex<Option<Arc<dyn SocketFactory<TcpSocket>>>>> =
    LazyLock::new(|| Mutex::new(None));

/// Configures the socket factory used to reach all ingest hosts.
pub(crate) fn configure(tcp: Arc<dyn SocketFactory<TcpSocket>>) {
    *SOCKET_FACTORY.lock() = Some(tcp);
}

/// Resets the shared socket factory so the next connection rebinds.
pub(crate) fn reset_socket_factory() {
    if let Some(tcp) = SOCKET_FACTORY.lock().clone() {
        tcp.reset();
    }
}

/// A self-healing HTTP/2 client for a single ingest host.
///
/// The host is resolved through [`tunnel_bypass_resolver`] and the connection
/// goes through the configured tunnel-bypassing socket factory, so telemetry
/// never loops through connlib. The connection is re-established on demand
/// when it is closed.
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

    pub(crate) async fn connect(&self) {
        let _ = self.connection().await;
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
        let tcp = SOCKET_FACTORY
            .lock()
            .clone()
            .context("Ingest client has no socket factory configured")?;

        // Anchor the connection task on our own runtime so it outlives the caller,
        // which may be a short-lived `block_on` on another runtime.
        RUNTIME
            .spawn(async move {
                let addresses = tunnel_bypass_resolver::resolve(host).await?;

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
    runtime.spawn(crate::feature_flags::reeval_on_resolver_change());

    runtime
}
