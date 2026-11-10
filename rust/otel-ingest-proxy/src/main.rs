#![cfg_attr(test, allow(clippy::unwrap_used))]

mod auth;
mod ingest;
mod rate_limit;
mod sanitize;
mod server;

#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

use anyhow::{Context as _, Result};
use bin_shared::http_health_check;
use clap::Parser;
use otel_azure_export::OtlpAuth;
use std::net::SocketAddr;
use std::num::NonZeroU32;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio_rustls::TlsAcceptor;
use tracing_subscriber::layer::Identity;
use url::Url;

use crate::auth::Verifier;
use crate::ingest::{Ingest, Metrics, Upstream};
use crate::rate_limit::RateLimiter;
use crate::server::CertResolver;

const RATE_LIMIT_EVICTION_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Parser, Debug)]
struct Args {
    /// The address to serve OTLP/HTTPS on.
    #[arg(long, env, default_value = "0.0.0.0:443")]
    listen_addr: SocketAddr,
    /// Path to the PEM-encoded TLS certificate chain.
    #[arg(long, env)]
    tls_cert_path: PathBuf,
    /// Path to the PEM-encoded TLS private key.
    #[arg(long, env)]
    tls_key_path: PathBuf,
    /// How often to reload the TLS certificate and key, in seconds.
    #[arg(long, env, hide = true, default_value_t = 60)]
    tls_reload_interval_secs: u64,

    /// Path to the PEM-encoded Ed25519 public key of the portal, used to verify device tokens.
    #[arg(long, env)]
    jwt_public_key_path: PathBuf,

    /// Full OTLP/HTTP metrics URL to forward device metrics to, used verbatim.
    #[arg(long, env)]
    otlp_forward_endpoint: Url,
    /// How to authenticate requests to `otlp_forward_endpoint` and `otlp_metrics_endpoint`.
    #[arg(long, env)]
    otlp_auth: Option<OtlpAuth>,
    /// Full OTLP/HTTP metrics URL for the proxy's own metrics, used verbatim.
    #[arg(long, env)]
    otlp_metrics_endpoint: Option<Url>,

    /// The largest request body to accept, in bytes.
    #[arg(long, env, default_value_t = 64 * 1024)]
    max_body_bytes: usize,
    /// How many requests to handle concurrently; further requests wait.
    #[arg(long, env, default_value_t = 256)]
    max_concurrent_requests: usize,

    /// How many requests a device may make per minute.
    #[arg(long, env, default_value = "12")]
    device_requests_per_minute: NonZeroU32,
    /// How many requests a device may make in a burst.
    #[arg(long, env, default_value = "6")]
    device_burst: NonZeroU32,
    /// How many devices to track for rate limiting at most.
    #[arg(long, env, default_value_t = 100_000)]
    max_rate_limited_devices: usize,
    /// How many requests all devices of an account may make per minute.
    #[arg(long, env, default_value = "30000")]
    account_requests_per_minute: NonZeroU32,
    /// How many requests all devices of an account may make in a burst.
    #[arg(long, env, default_value = "3000")]
    account_burst: NonZeroU32,
    /// How many accounts to track for rate limiting at most.
    #[arg(long, env, default_value_t = 10_000)]
    max_rate_limited_accounts: usize,

    #[command(flatten)]
    health_check: http_health_check::HealthCheckArgs,

    /// How to format the logs.
    #[arg(long, env, default_value = "human", hide = true)]
    log_format: LogFormat,

    /// How many worker threads to use.
    #[arg(long, env, hide = true, default_value = "2")]
    num_worker_threads: usize,
}

#[derive(clap::ValueEnum, Debug, Clone, Copy)]
enum LogFormat {
    Human,
    Json,
}

fn main() -> ExitCode {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    let args = Args::parse();

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(args.num_worker_threads)
        .enable_all()
        .build()
        .expect("Failed to build tokio runtime");

    match runtime.block_on(try_main(args)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            tracing::error!("{e:#}");
            ExitCode::FAILURE
        }
    }
}

async fn try_main(args: Args) -> Result<()> {
    let directives = std::env::var("RUST_LOG").unwrap_or_else(|_| "info".to_string());
    logging::setup_global_subscriber(
        directives,
        Identity::default(),
        Identity::default(),
        match args.log_format {
            LogFormat::Human => false,
            LogFormat::Json => true,
        },
    )?;

    setup_meter_provider(&args)?;

    otel_azure_export::check_endpoint(&args.otlp_forward_endpoint)
        .context("Invalid OTLP forward endpoint")?;

    let cert_resolver = Arc::new(CertResolver::load(
        args.tls_cert_path.clone(),
        args.tls_key_path.clone(),
    )?);
    let tls = TlsAcceptor::from(Arc::new(cert_resolver.clone().server_config()));

    let jwt_public_key = std::fs::read(&args.jwt_public_key_path).with_context(|| {
        format!(
            "Failed to read JWT public key from {}",
            args.jwt_public_key_path.display()
        )
    })?;

    let ingest = Arc::new(Ingest {
        verifier: Verifier::from_ed_pem(&jwt_public_key)?,
        device_limiter: RateLimiter::new(
            args.device_requests_per_minute,
            args.device_burst,
            args.max_rate_limited_devices,
        ),
        account_limiter: RateLimiter::new(
            args.account_requests_per_minute,
            args.account_burst,
            args.max_rate_limited_accounts,
        ),
        max_body_bytes: args.max_body_bytes,
        upstream: Upstream::new(args.otlp_forward_endpoint.clone(), args.otlp_auth)?,
        metrics: Metrics::new(),
    });

    tokio::spawn(reload_certificate(
        cert_resolver,
        Duration::from_secs(args.tls_reload_interval_secs),
    ));
    tokio::spawn(evict_idle_rate_limits(ingest.clone()));
    tokio::spawn(http_health_check::serve_with_version(
        args.health_check.health_check_addr,
        git_sha::git_sha(),
        || true,
    ));

    let listener = tokio::net::TcpListener::bind(args.listen_addr)
        .await
        .with_context(|| format!("Failed to listen on {}", args.listen_addr))?;

    tracing::info!(addr = %args.listen_addr, "Listening for OTLP metrics");

    server::serve(
        listener,
        tls,
        ingest::router(ingest, args.max_concurrent_requests),
    )
    .await?;

    Ok(())
}

fn setup_meter_provider(args: &Args) -> Result<()> {
    use opentelemetry::KeyValue;
    use opentelemetry_sdk::Resource;
    use opentelemetry_sdk::resource::{EnvResourceDetector, TelemetryResourceDetector};

    let Some(endpoint) = &args.otlp_metrics_endpoint else {
        return Ok(());
    };

    let resource = Resource::builder_empty()
        .with_service_name("otel-ingest-proxy")
        .with_attribute(KeyValue::new("service.namespace", "firezone"))
        .with_detector(Box::new(TelemetryResourceDetector))
        .with_detector(Box::new(EnvResourceDetector::new()))
        .build();
    let builder = opentelemetry_sdk::metrics::SdkMeterProvider::builder().with_resource(resource);

    // Reqwest's blocking client initializes its own runtime.
    let builder = tokio::task::block_in_place(|| {
        otel_azure_export::with_exporter(builder, endpoint, args.otlp_auth)
    })?;
    opentelemetry::global::set_meter_provider(builder.build());

    Ok(())
}

async fn reload_certificate(cert_resolver: Arc<CertResolver>, interval: Duration) {
    let mut interval = tokio::time::interval(interval);

    loop {
        interval.tick().await;

        if let Err(e) = cert_resolver.reload() {
            tracing::warn!("Failed to reload TLS certificate: {e:#}");
        }
    }
}

async fn evict_idle_rate_limits(ingest: Arc<Ingest>) {
    let mut interval = tokio::time::interval(RATE_LIMIT_EVICTION_INTERVAL);

    loop {
        interval.tick().await;

        let now = Instant::now();
        ingest.device_limiter.evict_idle(now);
        ingest.account_limiter.evict_idle(now);
    }
}
