use clap::Parser;
use clap::ValueEnum;
use goose::config::GooseConfiguration;
use goose::prelude::*;
use gumdrop::Options as _;
use std::sync::OnceLock;
use std::time::Duration;
use url::Url;

/// Global HTTP version configuration set from CLI args.
///
/// Goose transactions are static functions, so we use a global to pass configuration.
static HTTP_VERSION: OnceLock<HttpVersion> = OnceLock::new();

/// Default request timeout in seconds.
const DEFAULT_TIMEOUT_SECS: u64 = 60;

/// Goose options help text appended to HTTP subcommand help.
const GOOSE_HELP: &str = r#"
GOOSE OPTIONS (forwarded):
  -H, --host <HOST>        Target host URL
  -u, --users <N>          Concurrent users (default: 10)
  -t, --run-time <TIME>    Duration (e.g., 30s, 5m, 1h)
  --report-file <FILE>     Generate report (.html, .json, .md)
  --no-print-metrics       Suppress human-readable metrics output
  -q                       Quiet mode (-qq, -qqq for less)

See: https://book.goose.rs/getting-started/runtime-options.html
"#;

#[derive(Parser)]
#[command(after_long_help = GOOSE_HELP)]
pub struct Args {
    /// HTTP version to use (1 or 2)
    #[arg(long, default_value = "1", value_name = "VERSION")]
    pub http_version: HttpVersion,

    /// Arguments passed to Goose
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub goose_args: Vec<String>,
}

/// HTTP protocol version to use for load testing.
#[derive(Debug, Clone, Copy, ValueEnum, Default, PartialEq, Eq)]
pub enum HttpVersion {
    /// HTTP/1.1 - widely supported, connection-per-request
    #[default]
    #[value(name = "1", alias = "1.1", alias = "http1")]
    Http1,

    /// HTTP/2 - multiplexed streams, header compression
    #[value(name = "2", alias = "http2")]
    Http2,
}

impl HttpVersion {
    /// Configure a reqwest `ClientBuilder` for this HTTP version.
    pub fn configure_client(self, timeout: Duration) -> reqwest::ClientBuilder {
        let builder = reqwest::ClientBuilder::new()
            .timeout(timeout)
            .gzip(true)
            .cookie_store(true);

        match self {
            Self::Http1 => builder.http1_only(),
            Self::Http2 => builder.http2_prior_knowledge(),
        }
    }

    /// Returns display name for metrics output.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Http1 => "HTTP/1.1",
            Self::Http2 => "HTTP/2",
        }
    }
}

impl std::fmt::Display for HttpVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Simplified metrics summary for Azure log ingestion.
#[derive(serde::Serialize)]
struct HttpTestSummary {
    #[serde(skip_serializing_if = "Option::is_none")]
    seed: Option<u64>,
    test_type: &'static str,
    http_version: String,
    target_host: String,
    duration_secs: usize,
    total_requests: usize,
    successful_requests: usize,
    failed_requests: usize,
    min_response_time_ms: usize,
    max_response_time_ms: usize,
    avg_response_time_ms: usize,
}

impl HttpTestSummary {
    #[expect(
        clippy::disallowed_methods,
        reason = "Iterating to find our single endpoint"
    )]
    fn from_metrics(metrics: &GooseMetrics, http_version: HttpVersion, seed: Option<u64>) -> Self {
        let (total_requests, successful_requests, failed_requests, min_time, max_time, avg_time) =
            metrics
                .requests
                .values()
                .next()
                .map(|r| {
                    let avg = if r.raw_data.counter > 0 {
                        r.raw_data.total_time / r.raw_data.counter
                    } else {
                        0
                    };
                    (
                        r.raw_data.counter,
                        r.success_count,
                        r.fail_count,
                        r.raw_data.minimum_time,
                        r.raw_data.maximum_time,
                        avg,
                    )
                })
                .unwrap_or_default();

        let target_host = metrics
            .hosts
            .iter()
            .next()
            .cloned()
            .unwrap_or_else(|| "unknown".to_string());

        Self {
            seed,
            test_type: "http",
            http_version: http_version.to_string(),
            target_host,
            duration_secs: metrics.duration,
            total_requests,
            successful_requests,
            failed_requests,
            min_response_time_ms: min_time,
            max_response_time_ms: max_time,
            avg_response_time_ms: avg_time,
        }
    }
}

/// Resolved HTTP test parameters (ready to execute).
#[derive(Debug)]
pub struct TestConfig {
    pub address: Url,
    pub http_version: u8,
    pub users: u64,
    pub run_time: Duration,
}

/// Run HTTP test with manual CLI args.
pub async fn run_with_cli_args(args: Args) -> anyhow::Result<()> {
    HTTP_VERSION
        .set(args.http_version)
        .expect("HTTP_VERSION already set");

    // Parse Goose configuration from forwarded args
    let goose_args: Vec<&str> = args.goose_args.iter().map(String::as_str).collect();
    let config = GooseConfiguration::parse_args_default(&goose_args)
        .map_err(|e| anyhow::anyhow!("Failed to parse Goose arguments: {e}"))?;

    let metrics = GooseAttack::initialize_with_config(config)?
        .register_scenario(
            scenario!("LoadTest")
                .register_transaction(transaction!(setup_http_client).set_on_start())
                .register_transaction(transaction!(load_test_request)),
        )
        .execute()
        .await?;

    let http_version = HTTP_VERSION.get().copied().unwrap_or_default();
    let summary = HttpTestSummary::from_metrics(&metrics, http_version, None);
    println!(
        "{}",
        serde_json::to_string(&summary).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Run HTTP test from resolved config.
pub async fn run_with_config(config: TestConfig, seed: u64) -> anyhow::Result<()> {
    let http_version = match config.http_version {
        1 => HttpVersion::Http1,
        2 => HttpVersion::Http2,
        _ => HttpVersion::Http1,
    };

    // Ignore if already set (can happen in tests)
    let _ = HTTP_VERSION.set(http_version);

    // Build Goose args from resolved config
    let run_time_secs = config.run_time.as_secs();
    let address = config.address.to_string();
    let users = config.users.to_string();
    let run_time = format!("{run_time_secs}s");
    let goose_args: &[&str] = &[
        "--host",
        &address,
        "--users",
        &users,
        "--run-time",
        &run_time,
        "--no-print-metrics",
        "-qq",
    ];

    let goose_args_ref: Vec<&str> = goose_args.to_vec();
    let goose_config = GooseConfiguration::parse_args_default(&goose_args_ref)
        .map_err(|e| anyhow::anyhow!("Failed to parse Goose arguments: {e}"))?;

    let metrics = GooseAttack::initialize_with_config(goose_config)?
        .register_scenario(
            scenario!("LoadTest")
                .register_transaction(transaction!(setup_http_client).set_on_start())
                .register_transaction(transaction!(load_test_request)),
        )
        .execute()
        .await?;

    let summary = HttpTestSummary::from_metrics(&metrics, http_version, Some(seed));
    println!(
        "{}",
        serde_json::to_string(&summary).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Configure the HTTP client with the specified HTTP version.
///
/// This runs once per user at startup via `set_on_start()`.
async fn setup_http_client(user: &mut GooseUser) -> TransactionResult {
    let http_version = HTTP_VERSION.get().copied().unwrap_or_default();
    let timeout = Duration::from_secs(DEFAULT_TIMEOUT_SECS);

    let builder = http_version.configure_client(timeout);
    user.set_client_builder(builder).await?;

    Ok(())
}

/// Performs an HTTP GET request and validates the response.
async fn load_test_request(user: &mut GooseUser) -> TransactionResult {
    let mut goose = user.get("/").await?;

    if let Ok(response) = goose.response
        && !response.status().is_success()
    {
        let status = response.status();
        let url = user.base_url.as_str();

        tracing::warn!(
            status = %status,
            url = %url,
            "request failed"
        );

        return user.set_failure(&format!("{status}"), &mut goose.request, None, None);
    }

    Ok(())
}
