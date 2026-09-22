//! Receives the OpenTelemetry metrics Firezone gateways report and forwards
//! them to Azure Monitor, attributed to the gateway their token names.

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod auth;
mod forward;
mod server;

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{Context as _, Result};
use clap::Parser;
use tracing_subscriber::EnvFilter;
use url::Url;

#[derive(Parser)]
struct Args {
    #[arg(
        long,
        env = "TELEMETRY_INGEST_LISTEN_ADDR",
        default_value = "0.0.0.0:8080"
    )]
    listen_addr: SocketAddr,
    /// The Ed25519 public keys metrics tokens may be signed with, as
    /// comma-separated `kid:base64-public-key` pairs.
    #[arg(long, env = "TELEMETRY_INGEST_JWT_PUBLIC_KEYS")]
    jwt_public_keys: String,
    /// The Azure Monitor data collection endpoint reports are forwarded to.
    #[arg(long, env = "TELEMETRY_INGEST_DCE_METRICS_ENDPOINT")]
    dce_metrics_endpoint: Url,
    /// The client id of the user-assigned managed identity that authenticates
    /// us to Azure Monitor.
    #[arg(long, env = "TELEMETRY_INGEST_AZURE_CLIENT_ID")]
    azure_client_id: String,
    /// When set, only requests carrying this Azure Front Door id are served.
    #[arg(long, env = "TELEMETRY_INGEST_EXPECTED_FRONT_DOOR_ID")]
    expected_front_door_id: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    let keys = auth::PublicKeys::parse(&args.jwt_public_keys)
        .context("Failed to parse the configured JWT public keys")?;

    let sink = forward::AzureMonitor::new(
        reqwest::Client::new(),
        args.dce_metrics_endpoint,
        args.azure_client_id,
    );

    let app = server::router(server::AppState {
        keys: Arc::new(keys),
        sink: Arc::new(sink),
        expected_front_door_id: args.expected_front_door_id.map(Arc::from),
    });

    let listener = tokio::net::TcpListener::bind(args.listen_addr)
        .await
        .with_context(|| format!("Failed to listen on {}", args.listen_addr))?;

    tracing::info!(addr = %args.listen_addr, "Listening for metrics reports");

    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .context("Server failed")?;

    Ok(())
}
