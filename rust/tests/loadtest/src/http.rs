use std::time::Duration;

use anyhow::Context;
use anyhow::Result;

use clap::Parser;
use clap::ValueEnum;
use rand::RngExt;
use rand::SeedableRng as _;
use tracing::Instrument;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// Default maximum number of concurrent connections.
const DEFAULT_MAX_CONNECTIONS: u64 = 10;

/// Default HTTP version.
const DEFAULT_HTTP_VERSION: u8 = 1;

#[derive(Parser)]
pub struct Args {
    /// HTTP version to use (1 or 2). Overrides the config; default 1.
    #[arg(long, value_name = "VERSION")]
    http_version: Option<HttpVersion>,

    /// The address to GET. Overrides the config's `[http]` addresses.
    #[arg(long)]
    address: Option<String>,

    /// The maximum number of concurrent connections.
    #[arg(long)]
    max_connections: Option<u64>,
}

/// HTTP protocol version to use for load testing.
#[derive(Debug, Clone, Copy, ValueEnum, Default, PartialEq, Eq)]
enum HttpVersion {
    #[default]
    #[value(name = "1", alias = "1.1", alias = "http1")]
    Http1,

    #[value(name = "2", alias = "http2")]
    Http2,
}

impl HttpVersion {
    fn to_u8(self) -> u8 {
        match self {
            Self::Http1 => 1,
            Self::Http2 => 2,
        }
    }
}

impl std::fmt::Display for HttpVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Http1 => "HTTP/1.1".fmt(f),
            Self::Http2 => "HTTP/2".fmt(f),
        }
    }
}

/// Resolved HTTP test parameters (ready to execute).
#[derive(Debug)]
pub struct TestConfig {
    pub address: String,
    pub max_connections: u64,
    pub http_version: u8,
}

/// Build a [`TestConfig`] from CLI args, filling unspecified values from `base`.
pub fn merge(args: Args, base: Option<TestConfig>) -> Result<TestConfig> {
    let base = base.as_ref();

    let address = args
        .address
        .or_else(|| base.map(|b| b.address.clone()))
        .context("--address is required (or add [http] to the config)")?;
    let max_connections = args
        .max_connections
        .or_else(|| base.map(|b| b.max_connections))
        .unwrap_or(DEFAULT_MAX_CONNECTIONS);
    let http_version = args
        .http_version
        .map(HttpVersion::to_u8)
        .or_else(|| base.map(|b| b.http_version))
        .unwrap_or(DEFAULT_HTTP_VERSION);

    Ok(TestConfig {
        address,
        max_connections,
        http_version,
    })
}

/// Run HTTP test from CLI args merged over an optional config base.
pub async fn run_with_args(args: Args, base: Option<TestConfig>, seed: u64) -> Result<()> {
    run_with_config(merge(args, base)?, seed).await
}

/// Run HTTP test from resolved config.
pub async fn run_with_config(config: TestConfig, seed: u64) -> Result<()> {
    run(config, seed).await?;

    Ok(())
}

async fn run(config: TestConfig, seed: u64) -> Result<()> {
    let client = build_client(&config)?;
    let mut rng = rand::rngs::StdRng::seed_from_u64(seed);

    let num_connections = rng.random_range(1..=config.max_connections);

    tracing::info!(
        url = %config.address,
        max_connections = %config.max_connections,
        http_version = %config.http_version,
        %num_connections,
        %seed,
        "Starting HTTP connection test"
    );

    let mut connections = tokio::task::JoinSet::new();

    for id in 0..num_connections {
        connections.spawn(
            run_single_connection(client.clone(), config.address.clone())
                .instrument(tracing::info_span!("connection", %id)),
        );
    }

    connections
        .join_all()
        .await
        .into_iter()
        .collect::<Result<Vec<_>>>()?;

    tracing::info!("HTTP connection test complete");

    Ok(())
}

#[tracing::instrument(err)]
async fn run_single_connection(client: reqwest::Client, address: String) -> Result<()> {
    tracing::trace!("Sending GET request");

    let response = client
        .get(address)
        .send()
        .await
        .context("Failed to send request")?;

    let status = response.status();

    // Finish all the IO.
    let _text = response.text().await?;

    // TODO: If text/html, crawl for further links.

    tracing::trace!(%status, "Response received");

    Ok(())
}

fn build_client(config: &TestConfig) -> Result<reqwest::Client> {
    let builder = reqwest::ClientBuilder::new()
        .connect_timeout(CONNECT_TIMEOUT)
        .connection_verbose(true);
    let builder = match config.http_version {
        1 => builder.http1_only(),
        2 => builder.http2_prior_knowledge(),
        other => anyhow::bail!("Unsupported HTTP version: {other}"),
    };
    let client = builder.build().context("Failed to build HTTP client")?;

    Ok(client)
}
