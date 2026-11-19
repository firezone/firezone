mod server;

#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

use anyhow::{Context as _, Result};
use base64::Engine as _;
use bin_shared::http_health_check;
use clap::Parser;
use firezone_otel_ingest_proxy::{Ingest, Verifier};
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio_rustls::TlsAcceptor;
use tracing_subscriber::layer::Identity;
use url::Url;

use crate::server::CertResolver;

const LISTEN_ADDR: SocketAddr = SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 443);
const TLS_RELOAD_INTERVAL: Duration = Duration::from_secs(60);
const RATE_LIMIT_EVICTION_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Parser, Debug)]
struct Args {
    /// Path to the PEM-encoded TLS certificate chain.
    #[arg(long, env)]
    tls_cert_path: PathBuf,
    /// Path to the PEM-encoded TLS private key.
    #[arg(long, env)]
    tls_key_path: PathBuf,

    /// Base64-encoded PEM of the portal's Ed25519 public key, used to verify device tokens.
    #[arg(long, env)]
    jwt_public_key: String,

    /// Full OTLP/HTTP metrics URL to forward device metrics and export the proxy's own metrics to, used verbatim.
    #[arg(long, env)]
    otlp_metrics_endpoint: Url,

    /// Enables Sentry crash-reporting under this environment.
    #[arg(long, env, value_parser = ["production", "staging"])]
    telemetry_env: Option<String>,

    #[command(flatten)]
    health_check: http_health_check::HealthCheckArgs,
}

fn main() -> ExitCode {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    let args = Args::parse();

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to build tokio runtime");

    if let Some(env) = &args.telemetry_env {
        let release = git_sha::git_sha().expect(
            "otel-ingest-proxy binary was not patched with a release SHA before enabling telemetry",
        );
        telemetry::configure(Arc::new(socket_factory::tcp));
        telemetry::start(env, release, telemetry::OTEL_INGEST_PROXY_DSN);
    }

    let code = match runtime.block_on(try_main(args)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            tracing::error!("{e:#}");
            ExitCode::FAILURE
        }
    };

    telemetry::stop();

    code
}

async fn try_main(args: Args) -> Result<()> {
    let directives = std::env::var("RUST_LOG").unwrap_or_else(|_| "info".to_string());
    logging::setup_global_subscriber(directives, Identity::default(), Identity::default(), false)?;

    setup_meter_provider(&args.otlp_metrics_endpoint)?;

    let cert_resolver = Arc::new(CertResolver::load(
        args.tls_cert_path.clone(),
        args.tls_key_path.clone(),
    )?);
    let tls = TlsAcceptor::from(Arc::new(cert_resolver.clone().server_config()));

    let jwt_public_key = base64::engine::general_purpose::STANDARD
        .decode(args.jwt_public_key.trim())
        .context("JWT public key is not valid base64")?;

    let ingest = Arc::new(Ingest::new(
        Verifier::from_ed_pem(&jwt_public_key)?,
        &args.otlp_metrics_endpoint,
    )?);

    tokio::spawn(reload_certificate(cert_resolver));
    tokio::spawn(evict_idle_rate_limits(ingest.clone()));
    tokio::spawn(http_health_check::serve_with_version(
        args.health_check.health_check_addr,
        git_sha::git_sha(),
        || true,
    ));

    let listener = tokio::net::TcpListener::bind(LISTEN_ADDR)
        .await
        .with_context(|| format!("Failed to listen on {LISTEN_ADDR}"))?;

    tracing::info!(addr = %LISTEN_ADDR, "Listening for OTLP metrics");

    server::serve(listener, tls, firezone_otel_ingest_proxy::router(ingest)).await?;

    Ok(())
}

fn setup_meter_provider(endpoint: &Url) -> Result<()> {
    use opentelemetry::KeyValue;
    use opentelemetry_sdk::Resource;
    use opentelemetry_sdk::resource::{EnvResourceDetector, TelemetryResourceDetector};

    let resource = Resource::builder_empty()
        .with_service_name("otel-ingest-proxy")
        .with_attribute(KeyValue::new("service.namespace", "firezone"))
        .with_detector(Box::new(TelemetryResourceDetector))
        .with_detector(Box::new(EnvResourceDetector::new()))
        .build();
    let builder = opentelemetry_sdk::metrics::SdkMeterProvider::builder().with_resource(resource);

    // Reqwest's blocking client initializes its own runtime.
    let builder =
        tokio::task::block_in_place(|| otel_azure_export::with_exporter(builder, endpoint))?;
    opentelemetry::global::set_meter_provider(builder.build());

    Ok(())
}

async fn reload_certificate(cert_resolver: Arc<CertResolver>) {
    let mut interval = tokio::time::interval(TLS_RELOAD_INTERVAL);

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

        ingest.evict_idle_rate_limits(Instant::now());
    }
}
