use std::time::Duration;

use anyhow::Context;
use anyhow::Result;

use clap::Parser;
use clap::ValueEnum;
use rand::Rng;
use rand::SeedableRng as _;
use tracing::Instrument;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Parser)]
pub struct Args {
    /// HTTP version to use (1 or 2)
    #[arg(long, default_value = "1", value_name = "VERSION")]
    http_version: HttpVersion,

    /// The address to GET.
    #[arg(long)]
    address: String,

    /// The maximum number of concurrent connections.
    #[arg(long, default_value_t = 10)]
    max_connections: u64,
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

/// Run HTTP test with manual CLI args.
pub async fn run_with_cli_args(args: Args) -> Result<()> {
    let config = TestConfig {
        address: args.address,
        max_connections: args.max_connections,
        http_version: match args.http_version {
            HttpVersion::Http1 => 1,
            HttpVersion::Http2 => 2,
        },
    };

    run(config, 0).await?;

    Ok(())
}

/// Run HTTP test from resolved config.
pub async fn run_with_config(config: TestConfig, seed: u64) -> Result<()> {
    run(config, seed).await?;

    Ok(())
}

async fn run(config: TestConfig, seed: u64) -> Result<()> {
    let client = build_client(&config)?;
    let mut rng = rand::rngs::StdRng::seed_from_u64(seed);

    let num_connections = rng.gen_range(1..=config.max_connections);

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
