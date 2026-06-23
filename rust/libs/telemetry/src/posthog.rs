use std::{
    net::{IpAddr, ToSocketAddrs as _},
    sync::{Arc, LazyLock},
};

use anyhow::{Context as _, ErrorExt as _, Result};
use bootstrap_dns_client::BootstrapDnsClient;
use bytes::Bytes;
use http::{Method, Request, Response, header};
use http_client::HttpClient;
use parking_lot::Mutex;
use serde::Serialize;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use tokio::runtime::Runtime;

use crate::Env;

pub(crate) const API_KEY_PROD: &str = "phc_uXXl56plyvIBHj81WwXBLtdPElIRbm7keRTdUCmk8ll";
pub(crate) const API_KEY_STAGING: &str = "phc_tHOVtq183RpfKmzadJb4bxNpLM5jzeeb1Gu8YSH3nsK";
pub(crate) const API_KEY_ON_PREM: &str = "phc_4R9Ii6q4SEofVkH7LvajwuJ3nsGFhCj0ZlfysS2FNc";

const INGEST_HOST: &str = "posthog.firezone.dev";

pub(crate) static RUNTIME: LazyLock<Runtime> = LazyLock::new(init_runtime);

/// Process-wide HTTP client for PostHog's ingest host.
static INGEST: LazyLock<Ingest> = LazyLock::new(Ingest::default);

pub(crate) fn api_key_for_env(env: Env) -> Option<&'static str> {
    match env {
        Env::Production => Some(API_KEY_PROD),
        Env::Staging => Some(API_KEY_STAGING),
        Env::OnPrem => Some(API_KEY_ON_PREM),
        Env::Entrypoint | Env::DockerCompose | Env::Localhost => None,
    }
}

/// Configures the socket factories used to reach the ingest host.
///
/// In connlib processes these must bypass the tunnel so that telemetry traffic
/// never loops back through connlib; other processes pass plain socket factories.
pub(crate) fn configure(
    tcp: Arc<dyn SocketFactory<TcpSocket>>,
    udp: Arc<dyn SocketFactory<UdpSocket>>,
) {
    *INGEST.sockets.lock() = Some((tcp, udp));
}

/// Updates the upstream resolvers used to look up the ingest host.
pub(crate) fn update_system_resolvers(servers: Vec<IpAddr>) {
    *INGEST.servers.lock() = servers;
}

/// Seeds the ingest-host addresses using the system resolver.
///
/// Resolves the ingest host via the operating system and keeps the result as a
/// fallback for when the bootstrap resolver has no servers or cannot resolve the
/// host. Must run at startup, before connlib reconfigures the system resolver, so
/// the lookup reaches the real upstream and not connlib itself.
pub(crate) fn init_addresses() {
    let addresses = (INGEST_HOST, 443u16)
        .to_socket_addrs()
        .inspect_err(|e| tracing::debug!("Failed to seed ingest host addresses: {e:#}"))
        .map(|addresses| addresses.map(|addr| addr.ip()).collect::<Vec<_>>())
        .unwrap_or_default();

    tracing::debug!(
        ?addresses,
        "Seeded ingest host addresses from system resolver"
    );

    *INGEST.seed_addresses.lock() = addresses;
}

/// Drops the current connection so the next request re-resolves and reconnects.
pub(crate) fn reset() {
    if let Some((tcp, udp)) = INGEST.sockets.lock().as_ref() {
        tcp.reset();
        udp.reset();
    }

    *INGEST.client.lock() = None;
}

/// Sends a JSON `POST` to `path` on the ingest host and returns the response.
pub(crate) async fn post_json<B>(path: &str, body: &B) -> Result<Response<Bytes>>
where
    B: Serialize,
{
    let client = ingest_client().await?;

    let request = Request::builder()
        .method(Method::POST)
        .uri(format!("https://{INGEST_HOST}{path}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Bytes::from(
            serde_json::to_vec(body).context("Failed to serialize request body")?,
        ))
        .context("Failed to build HTTP request")?;

    let response = match client.send_request(request) {
        Ok(response) => response.await,
        Err(e) => Err(e),
    };

    // A closed connection means the path is broken; discard the client so the
    // next request re-resolves and reconnects.
    if response
        .as_ref()
        .is_err_and(|e| e.any_is::<http_client::Closed>())
    {
        *INGEST.client.lock() = None;
    }

    response
}

/// Holds the state needed to (re-)establish a connection to the ingest host.
///
/// The connection is resolved via [`BootstrapDnsClient`] against the configured
/// upstream resolvers and established through a tunnel-bypassing [`SocketFactory`].
/// Resolving lazily on every (re-)connect — rather than once at startup — lets us
/// recover from having no resolvers yet and from the network path breaking. When
/// the bootstrap resolver yields nothing, we fall back to `seed_addresses`.
#[derive(Default)]
struct Ingest {
    sockets: Mutex<
        Option<(
            Arc<dyn SocketFactory<TcpSocket>>,
            Arc<dyn SocketFactory<UdpSocket>>,
        )>,
    >,
    servers: Mutex<Vec<IpAddr>>,
    /// Addresses resolved via the system resolver at startup, before connlib took
    /// over DNS. Used as a fallback when the bootstrap resolver yields nothing.
    seed_addresses: Mutex<Vec<IpAddr>>,
    client: Mutex<Option<HttpClient>>,
    /// Serialises bootstrapping so concurrent senders share a single connection.
    bootstrap: tokio::sync::Mutex<()>,
}

/// Returns a live client, bootstrapping a new connection if there is none.
async fn ingest_client() -> Result<HttpClient> {
    if let Some(client) = live_client() {
        return Ok(client);
    }

    let _guard = INGEST.bootstrap.lock().await;

    if let Some(client) = live_client() {
        return Ok(client);
    }

    let client = bootstrap().await?;
    *INGEST.client.lock() = Some(client.clone());

    Ok(client)
}

fn live_client() -> Option<HttpClient> {
    INGEST
        .client
        .lock()
        .as_ref()
        .filter(|client| !client.is_closed())
        .cloned()
}

async fn bootstrap() -> Result<HttpClient> {
    let (tcp, udp) = INGEST
        .sockets
        .lock()
        .clone()
        .context("Ingest client has no socket factories configured")?;
    let servers = INGEST.servers.lock().clone();
    let seed_addresses = INGEST.seed_addresses.lock().clone();

    // Anchor the connection task on our own runtime so it outlives the caller,
    // which may be a short-lived `block_on` on another runtime.
    RUNTIME
        .spawn(async move {
            // Resolve via the bootstrap resolver, which never uses the system
            // resolver (i.e. connlib), and add the addresses seeded at startup as
            // extra fallback candidates. `HttpClient` tries them in order and
            // connects to the first that works, so freshly resolved addresses are
            // preferred while the seed still lets us connect before any resolvers
            // are configured or when the resolver returns unreachable addresses.
            //
            // Skip the resolver while we have no upstreams yet (e.g. before connlib
            // reports the system DNS servers); it would only fail and the seed
            // already covers that case.
            let mut addresses = if servers.is_empty() {
                Vec::new()
            } else {
                BootstrapDnsClient::new(udp, tcp.clone(), servers)
                    .resolve(INGEST_HOST)
                    .await
                    .inspect_err(|e| tracing::debug!("Failed to resolve ingest host: {e:#}"))
                    .unwrap_or_default()
            };

            for address in seed_addresses {
                if !addresses.contains(&address) {
                    addresses.push(address);
                }
            }

            anyhow::ensure!(!addresses.is_empty(), "No addresses for ingest host");

            HttpClient::new(INGEST_HOST.to_owned(), addresses, tcp)
                .await
                .context("Failed to connect to ingest host")
        })
        .await
        .context("Bootstrap task failed")?
}

/// Initialize the runtime to use for evaluating feature flags.
fn init_runtime() -> Runtime {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1) // We only need 1 worker thread.
        .thread_name("posthog-worker")
        .enable_io()
        .enable_time()
        .build()
        .expect("to be able to build runtime");

    runtime.spawn(crate::feature_flags::reeval_timer());

    runtime
}
