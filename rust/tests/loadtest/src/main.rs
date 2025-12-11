#![expect(
    clippy::print_stdout,
    reason = "CLI tool outputs JSON metrics to stdout"
)]
#![cfg_attr(
    windows,
    expect(clippy::print_stderr, reason = "CLI tool outputs warnings to stderr")
)]
#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Load testing CLI for Firezone VPN.
//!
//! Supports HTTP, TCP, and WebSocket load testing.
//!
//! # Usage
//!
//! Run `firezone-loadtest -h` for all options
//! You can also see Goose docs: <https://book.goose.rs>
//!
//! ```bash
//! # Random test from config (default mode)
//! firezone-loadtest --config loadtest.toml
//!
//! # Reproducible random test with seed
//! firezone-loadtest --config loadtest.toml --seed 12345
//!
//! # HTTP/1.1 load test (manual mode)
//! firezone-loadtest http -H https://example.com -u 100 -t 60s
//!
//! # HTTP/2 load test
//! firezone-loadtest http --http-version 2 -H https://example.com -u 100 -t 60s
//! ```
//!
//! # For Azure log ingestion (clean JSON output)
//! ```bash
//! firezone-loadtest http -qq --no-print-metrics 2>/dev/null | tail -1
//! ```
//!
//! # Windows Event Log
//!
//! On Windows, events are logged to the Application Event Log under source
//! "Firezone-Loadtest". Register the source (as admin) with:
//! ```powershell
//! New-EventLog -LogName Application -Source "Firezone-Loadtest"
//! ```

mod config;
mod echo_payload;
mod http_version;
mod ping;
mod tcp;
mod util;
mod websocket;

use clap::{Parser, Subcommand};
use config::{LoadTestConfig, ResolvedConfig, TestSelector};
use echo_payload::HEADER_SIZE;
use goose::config::GooseConfiguration;
use goose::metrics::GooseMetrics;
use goose::prelude::*;
use gumdrop::Options;
use http_version::HttpVersion;
use serde::Serialize;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Duration;
use tracing::info;
use tracing_subscriber::EnvFilter;
#[cfg(windows)]
use tracing_subscriber::util::SubscriberInitExt as _;
use url::Url;

#[cfg(windows)]
const EVENT_LOG_SOURCE: &str = "Firezone-Loadtest";

/// Global HTTP version configuration set from CLI args.
///
/// Goose transactions are static functions, so we use a global to pass configuration.
static HTTP_VERSION: OnceLock<HttpVersion> = OnceLock::new();

/// Default request timeout in seconds.
const DEFAULT_TIMEOUT_SECS: u64 = 60;

/// Default config file name.
const DEFAULT_CONFIG_FILE: &str = "loadtest.toml";

/// Default echo payload size in bytes for CLI commands.
const DEFAULT_ECHO_PAYLOAD_SIZE: usize = 64;

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
#[command(
    name = "firezone-loadtest",
    about = "Load testing CLI for Firezone VPN"
)]
struct Cli {
    /// Path to TOML configuration file (default: loadtest.toml)
    #[arg(long, global = true)]
    config: Option<PathBuf>,

    /// Random seed for reproducible test selection
    #[arg(long, global = true)]
    seed: Option<u64>,

    /// Print default configuration to stdout and exit
    #[arg(long)]
    dump_config: bool,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Random test from config file (default when no subcommand given)
    Random,
    /// HTTP load testing using Goose
    Http(HttpArgs),
    /// TCP connection load testing
    Tcp(TcpArgs),
    /// WebSocket connection load testing
    Websocket(WebsocketArgs),
    /// ICMP ping testing
    Ping(PingArgs),
}

#[derive(Parser)]
#[command(after_long_help = GOOSE_HELP)]
struct HttpArgs {
    /// HTTP version to use (1 or 2)
    #[arg(long, default_value = "1", value_name = "VERSION")]
    http_version: HttpVersion,

    /// Arguments passed to Goose
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    goose_args: Vec<String>,
}

#[derive(Parser)]
struct TcpArgs {
    /// Run as echo server (listen for connections)
    #[arg(long)]
    server: bool,

    /// Port to listen on (server mode only)
    #[arg(short = 'p', long, default_value = "9000")]
    port: u16,

    /// Target address (host:port) - required in client mode
    #[arg(long, value_name = "ADDR")]
    target: Option<SocketAddr>,

    /// Number of concurrent connections to establish
    #[arg(short = 'c', long, default_value = "10")]
    concurrent: usize,

    /// How long to hold each connection open (e.g., 30s, 5m)
    #[arg(short = 'd', long, default_value = "30s", value_parser = parse_duration)]
    duration: Duration,

    /// Connection timeout for establishing connections
    #[arg(long, default_value = "10s", value_parser = parse_duration)]
    timeout: Duration,

    /// Enable echo mode: send timestamped payloads and verify responses
    #[arg(long)]
    echo: bool,

    /// Echo payload size in bytes (minimum 16 for header)
    #[arg(long, default_value_t = DEFAULT_ECHO_PAYLOAD_SIZE, value_parser = parse_echo_payload_size)]
    echo_payload_size: usize,

    /// Interval between echo messages (e.g., 1s, 500ms)
    #[arg(long, value_parser = parse_duration)]
    echo_interval: Option<Duration>,

    /// Timeout for reading echo responses (e.g., 5s)
    #[arg(long, default_value = "5s", value_parser = parse_duration)]
    echo_read_timeout: Duration,
}

fn parse_echo_payload_size(s: &str) -> Result<usize, String> {
    let size: usize = s
        .parse()
        .map_err(|e| format!("invalid payload size: {e}"))?;
    if size < HEADER_SIZE {
        return Err(format!(
            "payload size must be at least {HEADER_SIZE} bytes (header size)"
        ));
    }
    Ok(size)
}

fn parse_ping_payload_size(s: &str) -> Result<usize, String> {
    let size: usize = s
        .parse()
        .map_err(|e| format!("invalid payload size: {e}"))?;
    if size > ping::MAX_ICMP_PAYLOAD_SIZE {
        return Err(format!(
            "payload size exceeds maximum ICMP payload of {} bytes",
            ping::MAX_ICMP_PAYLOAD_SIZE
        ));
    }
    Ok(size)
}

/// Duration suffixes: (suffix, seconds_multiplier, unit_name).
const DURATION_SUFFIXES: &[(&str, u64, &str)] = &[
    // "ms" must come before "m" to match correctly.
    ("ms", 0, "milliseconds"), // Special case: 0 means use millis
    ("s", 1, "seconds"),
    ("m", 60, "minutes"),
    ("h", 3600, "hours"),
];

fn parse_duration(s: &str) -> Result<Duration, String> {
    let s = s.trim();

    for &(suffix, multiplier, unit) in DURATION_SUFFIXES {
        if let Some(num_str) = s.strip_suffix(suffix) {
            let num: u64 = num_str
                .parse()
                .map_err(|e| format!("invalid {unit}: {e}"))?;
            return Ok(if multiplier == 0 {
                Duration::from_millis(num)
            } else {
                Duration::from_secs(num * multiplier)
            });
        }
    }

    // Default: treat as seconds
    s.parse::<u64>()
        .map(Duration::from_secs)
        .map_err(|e| format!("invalid duration (use 500ms, 30s, 5m, 1h): {e}"))
}

#[derive(Parser)]
struct WebsocketArgs {
    /// Run as echo server (listen for connections)
    #[arg(long)]
    server: bool,

    /// Port to listen on (server mode only)
    #[arg(short = 'p', long, default_value = "9001")]
    port: u16,

    /// WebSocket URL (ws:// or wss://) - required in client mode
    #[arg(long, value_name = "URL")]
    url: Option<Url>,

    /// Number of concurrent connections to establish
    #[arg(short = 'c', long, default_value = "10")]
    concurrent: usize,

    /// How long to hold each connection open (e.g., 30s, 5m)
    #[arg(short = 'd', long, default_value = "30s", value_parser = parse_duration)]
    duration: Duration,

    /// Connection timeout for establishing connections
    #[arg(long, default_value = "10s", value_parser = parse_duration)]
    timeout: Duration,

    /// Interval between ping messages to keep connection alive (e.g., 5s). Ignored in echo mode.
    #[arg(long, value_parser = parse_duration)]
    ping_interval: Option<Duration>,

    /// Enable echo mode: send timestamped payloads and verify responses
    #[arg(long)]
    echo: bool,

    /// Echo payload size in bytes (minimum 16 for header)
    #[arg(long, default_value_t = DEFAULT_ECHO_PAYLOAD_SIZE, value_parser = parse_echo_payload_size)]
    echo_payload_size: usize,

    /// Interval between echo messages (e.g., 1s, 500ms)
    #[arg(long, value_parser = parse_duration)]
    echo_interval: Option<Duration>,

    /// Timeout for reading echo responses (e.g., 5s)
    #[arg(long, default_value = "5s", value_parser = parse_duration)]
    echo_read_timeout: Duration,
}

#[derive(Parser)]
struct PingArgs {
    /// Target IP address(es) to ping
    #[arg(long, value_name = "IP", required = true, num_args = 1..)]
    target: Vec<IpAddr>,

    /// Number of pings per target
    #[arg(short = 'c', long)]
    count: Option<usize>,

    /// Run for specified duration instead of count (e.g., 60s, 5m)
    #[arg(short = 't', long, value_parser = parse_duration, conflicts_with = "count")]
    duration: Option<Duration>,

    /// Interval between pings (e.g., 1s, 500ms)
    #[arg(short = 'i', long, default_value = "1s", value_parser = parse_duration)]
    interval: Duration,

    /// Ping timeout (e.g., 5s)
    #[arg(long, default_value = "5s", value_parser = parse_duration)]
    timeout: Duration,

    /// ICMP payload size in bytes (max 65507)
    #[arg(short = 's', long, default_value = "56", value_parser = parse_ping_payload_size)]
    payload_size: usize,
}

/// Simplified metrics summary for Azure log ingestion.
#[derive(Serialize)]
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

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_logging();
    let cli = Cli::parse();

    if cli.dump_config {
        print!("{DEFAULT_CONFIG}");
        return Ok(());
    }

    match cli.command {
        None | Some(Commands::Random) => run_random(cli.config, cli.seed).await?,
        Some(Commands::Http(args)) => run_http_manual(args).await?,
        Some(Commands::Tcp(args)) => run_tcp_manual(args).await?,
        Some(Commands::Websocket(args)) => run_websocket_manual(args).await?,
        Some(Commands::Ping(args)) => run_ping_manual(args).await?,
    }

    Ok(())
}

/// Default configuration compiled from the example file.
const DEFAULT_CONFIG: &str = include_str!("../loadtest.example.toml");

/// Run a random test from the config file.
async fn run_random(config_path: Option<PathBuf>, seed: Option<u64>) -> anyhow::Result<()> {
    let config_path = config_path.unwrap_or_else(|| PathBuf::from(DEFAULT_CONFIG_FILE));

    if !config_path.exists() {
        anyhow::bail!(
            "Config file not found: {}\n\nCreate a loadtest.toml file or specify one with --config",
            config_path.display()
        );
    }

    info!(config = %config_path.display(), "Loading config");

    let config = LoadTestConfig::load(&config_path)?;
    let mut selector = TestSelector::new(seed);
    let seed = selector.seed();

    info!(seed, enabled_types = ?config.enabled_types(), "Selecting random test");

    let resolved = selector.select(&config);

    match resolved {
        ResolvedConfig::Http(ref http) => {
            info!(
                test_type = "http",
                seed,
                address = %http.address,
                http_version = http.http_version,
                users = http.users,
                duration_secs = http.run_time.as_secs(),
                "Starting HTTP test"
            );
        }
        ResolvedConfig::Tcp(ref tcp) => {
            info!(
                test_type = "tcp",
                seed,
                address = %tcp.address,
                concurrent = tcp.concurrent,
                duration_secs = tcp.duration.as_secs(),
                echo_mode = tcp.echo_mode,
                "Starting TCP test"
            );
        }
        ResolvedConfig::Websocket(ref ws) => {
            info!(
                test_type = "websocket",
                seed,
                url = %ws.address,
                concurrent = ws.concurrent,
                duration_secs = ws.duration.as_secs(),
                echo_mode = ws.echo_mode,
                "Starting WebSocket test"
            );
        }
        ResolvedConfig::Ping(ref ping) => {
            info!(
                test_type = "ping",
                seed,
                targets = ?ping.targets,
                count = ping.count,
                interval_ms = ping.interval.as_millis() as u64,
                "Starting ping test"
            );
        }
    }

    match resolved {
        ResolvedConfig::Http(http) => run_http_from_config(http, seed).await,
        ResolvedConfig::Tcp(tcp) => run_tcp_from_config(tcp, seed).await,
        ResolvedConfig::Websocket(ws) => run_websocket_from_config(ws, seed).await,
        ResolvedConfig::Ping(ping) => run_ping_from_config(ping, seed).await,
    }
}

/// Run HTTP test from resolved config.
async fn run_http_from_config(config: config::ResolvedHttpConfig, seed: u64) -> anyhow::Result<()> {
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

/// Run TCP test from resolved config.
async fn run_tcp_from_config(config: config::ResolvedTcpConfig, seed: u64) -> anyhow::Result<()> {
    let tcp_config = tcp::TcpTestConfig {
        target: config.address,
        concurrent: config.concurrent,
        hold_duration: config.duration,
        connect_timeout: config.timeout,
        echo_mode: config.echo_mode,
        echo_payload_size: config.echo_payload_size,
        echo_interval: config.echo_interval,
        echo_read_timeout: config.echo_read_timeout,
    };

    let summary = tcp::run(tcp_config).await?;
    println!(
        "{}",
        serde_json::to_string(&WithSeed::new(seed, summary)).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Run WebSocket test from resolved config.
async fn run_websocket_from_config(
    config: config::ResolvedWebsocketConfig,
    seed: u64,
) -> anyhow::Result<()> {
    let ws_config = websocket::WebsocketTestConfig {
        url: config.address,
        concurrent: config.concurrent,
        hold_duration: config.duration,
        connect_timeout: config.timeout,
        ping_interval: config.ping_interval,
        echo_mode: config.echo_mode,
        echo_payload_size: config.echo_payload_size,
        echo_interval: config.echo_interval,
        echo_read_timeout: config.echo_read_timeout,
    };

    let summary = websocket::run(ws_config).await?;
    println!(
        "{}",
        serde_json::to_string(&WithSeed::new(seed, summary)).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Run ping test from resolved config.
async fn run_ping_from_config(config: config::ResolvedPingConfig, seed: u64) -> anyhow::Result<()> {
    let ping_config = ping::PingTestConfig {
        targets: config.targets,
        count: Some(config.count),
        duration: None,
        interval: config.interval,
        timeout: config.timeout,
        payload_size: config.payload_size,
    };

    let summary = ping::run(ping_config).await?;
    println!(
        "{}",
        serde_json::to_string(&WithSeed::new(seed, summary)).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Generic wrapper to add a seed to any test summary for reproducibility.
#[derive(Serialize)]
struct WithSeed<T: Serialize> {
    seed: u64,
    #[serde(flatten)]
    inner: T,
}

impl<T: Serialize> WithSeed<T> {
    fn new(seed: u64, inner: T) -> Self {
        Self { seed, inner }
    }
}

/// Run HTTP test with manual CLI args.
async fn run_http_manual(args: HttpArgs) -> anyhow::Result<()> {
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

/// Run TCP test with manual CLI args.
async fn run_tcp_manual(args: TcpArgs) -> anyhow::Result<()> {
    if args.server {
        // Server mode
        let config = tcp::TcpServerConfig { port: args.port };
        tcp::run_server(config).await?;
    } else {
        // Client mode
        let target = args.target.ok_or_else(|| {
            anyhow::anyhow!("--target is required in client mode (or use --server for server mode)")
        })?;

        let config = tcp::TcpTestConfig {
            target,
            concurrent: args.concurrent,
            hold_duration: args.duration,
            connect_timeout: args.timeout,
            echo_mode: args.echo,
            echo_payload_size: args.echo_payload_size,
            echo_interval: args.echo_interval,
            echo_read_timeout: args.echo_read_timeout,
        };

        let summary = tcp::run(config).await?;
        println!(
            "{}",
            serde_json::to_string(&summary).expect("Failed to serialize metrics")
        );
    }

    Ok(())
}

/// Run WebSocket test with manual CLI args.
async fn run_websocket_manual(args: WebsocketArgs) -> anyhow::Result<()> {
    if args.server {
        // Server mode
        let config = websocket::WebsocketServerConfig { port: args.port };
        websocket::run_server(config).await?;
    } else {
        // Client mode
        let url = args.url.ok_or_else(|| {
            anyhow::anyhow!("--url is required in client mode (or use --server for server mode)")
        })?;

        let config = websocket::WebsocketTestConfig {
            url,
            concurrent: args.concurrent,
            hold_duration: args.duration,
            connect_timeout: args.timeout,
            ping_interval: args.ping_interval,
            echo_mode: args.echo,
            echo_payload_size: args.echo_payload_size,
            echo_interval: args.echo_interval,
            echo_read_timeout: args.echo_read_timeout,
        };

        let summary = websocket::run(config).await?;
        println!(
            "{}",
            serde_json::to_string(&summary).expect("Failed to serialize metrics")
        );
    }

    Ok(())
}

/// Run ping test with manual CLI args.
async fn run_ping_manual(args: PingArgs) -> anyhow::Result<()> {
    // Ensure at least count or duration is specified
    let (count, duration) = if args.count.is_none() && args.duration.is_none() {
        // Default to 10 pings if neither specified
        (Some(10), None)
    } else {
        (args.count, args.duration)
    };

    let config = ping::PingTestConfig {
        targets: args.target,
        count,
        duration,
        interval: args.interval,
        timeout: args.timeout,
        payload_size: args.payload_size,
    };

    let summary = ping::run(config).await?;
    println!(
        "{}",
        serde_json::to_string(&summary).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Initializes logging with optional Windows Event Log support.
///
/// On non-Windows platforms, uses RUST_LOG env var for filtering.
/// Default to info level for this crate, warn for dependencies.
fn init_logging() {
    #[cfg(windows)]
    {
        use tracing_subscriber::layer::SubscriberExt as _;

        match logging::windows_event_log::layer(EVENT_LOG_SOURCE) {
            Ok(layer) => {
                tracing_subscriber::registry().with(layer).init();
            }
            Err(e) => {
                eprintln!(
                    "Warning: Could not initialize Windows Event Log: {e}\n\
                    Events will not be logged to Event Viewer.\n\
                    Set EVENTLOG_DIRECTIVES to control Event Log filtering (default: info)."
                );
                tracing_subscriber::registry().init();
            }
        }
    }

    #[cfg(not(windows))]
    {
        // Initialize tracing with RUST_LOG env var support
        // Default to info level for this crate, warn for dependencies
        tracing_subscriber::fmt()
            .with_env_filter(
                EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| EnvFilter::new("firezone_loadtest=info,warn")),
            )
            .with_writer(std::io::stderr)
            .init();
    }
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
