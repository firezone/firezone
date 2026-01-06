use std::{net::ToSocketAddrs as _, sync::LazyLock, time::Duration};
use tokio::runtime::Runtime;

use crate::Env;

pub(crate) const API_KEY_PROD: &str = "phc_uXXl56plyvIBHj81WwXBLtdPElIRbm7keRTdUCmk8ll";
pub(crate) const API_KEY_STAGING: &str = "phc_tHOVtq183RpfKmzadJb4bxNpLM5jzeeb1Gu8YSH3nsK";
pub(crate) const API_KEY_ON_PREM: &str = "phc_4R9Ii6q4SEofVkH7LvajwuJ3nsGFhCj0ZlfysS2FNc";

pub(crate) static RUNTIME: LazyLock<Runtime> = LazyLock::new(init_runtime);
pub(crate) static CLIENT: LazyLock<reqwest::Result<reqwest::Client>> = LazyLock::new(init_client);

pub(crate) const INGEST_HOST: &str = "posthog.firezone.dev";

pub(crate) fn api_key_for_env(env: Env) -> Option<&'static str> {
    match env {
        Env::Production => Some(API_KEY_PROD),
        Env::Staging => Some(API_KEY_STAGING),
        Env::OnPrem => Some(API_KEY_ON_PREM),
        Env::DockerCompose | Env::Localhost => None,
    }
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

/// Initialize the client to use for evaluating feature flags.
fn init_client() -> reqwest::Result<reqwest::Client> {
    let ingest_host_addresses = (INGEST_HOST, 443u16)
        .to_socket_addrs()
        .inspect_err(|e| {
            tracing::error!("Failed to resolve ingest host (`{INGEST_HOST}`) IPs: {e:#}")
        })
        .unwrap_or_default()
        .collect::<Vec<_>>();

    tracing::debug!(host = %INGEST_HOST, addresses = ?ingest_host_addresses, "Resolved PostHog ingest host addresses");

    reqwest::ClientBuilder::new()
        .connection_verbose(true)
        .pool_idle_timeout(None) // Never remove idle connections.
        .pool_max_idle_per_host(1)
        .http2_prior_knowledge() // We know PostHog supports HTTP/2.
        .http2_keep_alive_timeout(Duration::from_secs(1))
        .http2_keep_alive_interval(Duration::from_secs(5)) // Use keep-alive to detect broken connections.
        .resolve_to_addrs(INGEST_HOST, &ingest_host_addresses)
        .build()
}
