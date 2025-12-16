#![expect(
    clippy::print_stdout,
    reason = "CLI tool outputs JSON metrics to stdout"
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
//! "FirezoneLoadtest". Register the source (as admin) with:
//! ```powershell
//! New-EventLog -LogName Application -Source "FirezoneLoadtest"
//! ```

mod cli;
mod config;
mod echo_payload;
mod http;
mod ping;
mod tcp;
mod util;
mod websocket;

use crate::config::{HttpConfig, MIN_PING_COUNT, PingConfig, TcpConfig, TestType, WebsocketConfig};
use clap::{Parser, Subcommand};
use config::LoadTestConfig;
use rand::rngs::StdRng;
use rand::seq::SliceRandom;
use rand::{Rng as _, SeedableRng as _};
use serde::Serialize;
use std::net::IpAddr;
use std::path::PathBuf;
use std::time::Duration;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::Layer as _;
use tracing_subscriber::layer::SubscriberExt as _;
use tracing_subscriber::util::SubscriberInitExt as _;
use url::Url;

/// Default config file name.
const DEFAULT_CONFIG_FILE: &str = "loadtest.toml";

/// Default echo payload size in bytes for CLI commands.
const DEFAULT_ECHO_PAYLOAD_SIZE: usize = 64;

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
    Http(http::Args),
    /// TCP connection load testing
    Tcp(tcp::Args),
    /// WebSocket connection load testing
    Websocket(websocket::Args),
    /// ICMP ping testing
    Ping(ping::Args),
}

#[tokio::main]
async fn main() {
    init_logging();

    match try_main().await {
        Ok(()) => {}
        Err(e) => {
            tracing::error!("{e:#}");
            std::process::exit(1);
        }
    }
}

async fn try_main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    if cli.dump_config {
        print!("{DEFAULT_CONFIG}");
        return Ok(());
    }

    match cli.command {
        None | Some(Commands::Random) => run_random(cli.config, cli.seed).await?,
        Some(Commands::Http(args)) => http::run_with_cli_args(args).await?,
        Some(Commands::Tcp(args)) => tcp::run_with_cli_args(args).await?,
        Some(Commands::Websocket(args)) => websocket::run_with_cli_args(args).await?,
        Some(Commands::Ping(args)) => ping::run_with_cli_args(args).await?,
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

    tracing::info!(config = %config_path.display(), "Loading config");

    let config = LoadTestConfig::load(&config_path)?;
    let mut selector = TestSelector::new(seed);
    let seed = selector.seed();

    tracing::info!(seed, enabled_types = ?config.enabled_types(), "Selecting random test");

    match selector.select(&config) {
        AnyTestConfig::Http(http) => http::run_with_config(http, seed).await,
        AnyTestConfig::Tcp(tcp) => tcp::run_with_config(tcp, seed).await,
        AnyTestConfig::Websocket(ws) => websocket::run_with_config(ws, seed).await,
        AnyTestConfig::Ping(ping) => ping::run_with_config(ping, seed).await,
    }
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

/// Initializes logging with optional Windows Event Log support.
#[expect(clippy::print_stderr, reason = "CLI tool outputs warnings to stderr")]
fn init_logging() {
    tracing_subscriber::registry()
        .with(
            logging::windows_event_log::layer("FirezoneLoadtest")
                .map(|l| l.boxed())
                .unwrap_or_else(|e| {
                    eprintln!("Failed to initialize Windows Event log: {e:#}");

                    tracing_subscriber::layer::Identity::new().boxed()
                }),
        )
        .with(
            tracing_subscriber::fmt::layer()
                .with_writer(std::io::stderr)
                .event_format(logging::Format::new()),
        )
        .with(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("firezone_loadtest=info,warn")),
        )
        .init();
}

/// Resolved test configuration (one of the test types).
#[derive(Debug)]
enum AnyTestConfig {
    Http(http::TestConfig),
    Tcp(tcp::TestConfig),
    Websocket(websocket::TestConfig),
    Ping(ping::TestConfig),
}

/// Random test selector.
struct TestSelector {
    rng: StdRng,
    seed: u64,
}

impl TestSelector {
    /// Create a new selector with the given seed, or generate a random one.
    fn new(seed: Option<u64>) -> Self {
        let seed = seed.unwrap_or_else(rand::random);
        let rng = StdRng::seed_from_u64(seed);
        Self { rng, seed }
    }

    fn seed(&self) -> u64 {
        self.seed
    }

    fn select(&mut self, config: &LoadTestConfig) -> AnyTestConfig {
        let types = config.enabled_types();
        let test_type = types[self.rng.gen_range(0..types.len())];

        match test_type {
            TestType::Http => AnyTestConfig::Http(self.resolve_http(&config.http)),
            TestType::Tcp => AnyTestConfig::Tcp(self.resolve_tcp(&config.tcp)),
            TestType::Websocket => {
                AnyTestConfig::Websocket(self.resolve_websocket(&config.websocket))
            }
            TestType::Ping => AnyTestConfig::Ping(self.resolve_ping(&config.ping)),
        }
    }

    fn resolve_http(&mut self, config: &HttpConfig) -> http::TestConfig {
        let address = config
            .addresses
            .choose(&mut self.rng)
            .expect("should have at least one address")
            .clone();
        let http_version = config
            .http_version
            .choose(&mut self.rng)
            .expect("should have at least one HTTP version");

        http::TestConfig {
            address,
            http_version: *http_version,
            max_connections: config.max_connections,
        }
    }

    fn resolve_tcp(&mut self, config: &TcpConfig) -> tcp::TestConfig {
        let address = config
            .addresses
            .choose(&mut self.rng)
            .expect("should have at least one address");

        let concurrent = self.rng.gen_range(config.concurrent) as usize;
        let duration = Duration::from_secs(self.rng.gen_range(config.duration_secs));
        let timeout = Duration::from_secs(self.rng.gen_range(config.timeout_secs));
        let echo_mode = config.echo_mode;
        let echo_payload_size = self.rng.gen_range(config.echo_payload_size) as usize;
        let echo_interval = Some(Duration::from_secs(
            self.rng.gen_range(config.echo_interval_secs),
        ));
        let echo_read_timeout =
            Duration::from_secs(self.rng.gen_range(config.echo_read_timeout_secs));

        tcp::TestConfig {
            target: address.to_owned(),
            concurrent,
            hold_duration: duration,
            connect_timeout: timeout,
            echo_mode,
            echo_payload_size,
            echo_interval,
            echo_read_timeout,
        }
    }

    fn resolve_websocket(&mut self, config: &WebsocketConfig) -> websocket::TestConfig {
        let address = config
            .addresses
            .choose(&mut self.rng)
            .expect("should have at least one address");
        let address = Url::parse(address).expect("URL validated during config load");

        let concurrent = self.rng.gen_range(config.concurrent) as usize;
        let duration = Duration::from_secs(self.rng.gen_range(config.duration_secs));
        let timeout = Duration::from_secs(self.rng.gen_range(config.timeout_secs));
        let ping_interval = Some(Duration::from_secs(
            self.rng.gen_range(config.ping_interval_secs),
        ));
        let echo_mode = config.echo_mode;
        let echo_payload_size = self.rng.gen_range(config.echo_payload_size) as usize;
        let echo_interval = Some(Duration::from_secs(
            self.rng.gen_range(config.echo_interval_secs),
        ));
        let echo_read_timeout =
            Duration::from_secs(self.rng.gen_range(config.echo_read_timeout_secs));

        websocket::TestConfig {
            url: address,
            concurrent,
            hold_duration: duration,
            connect_timeout: timeout,
            ping_interval,
            echo_mode,
            echo_payload_size,
            echo_interval,
            echo_read_timeout,
        }
    }

    fn resolve_ping(&mut self, config: &PingConfig) -> ping::TestConfig {
        // Parse all targets
        let targets: Vec<IpAddr> = config
            .addresses
            .iter()
            .map(|s| s.parse().expect("IP address validated during config load"))
            .collect();

        // Ensure minimum count of 1 ping
        let count = (self.rng.gen_range(config.count) as usize).max(MIN_PING_COUNT);
        let interval = Duration::from_millis(self.rng.gen_range(config.interval_ms));
        let timeout = Duration::from_millis(self.rng.gen_range(config.timeout_ms));
        let payload_size = self.rng.gen_range(config.payload_size) as usize;

        ping::TestConfig {
            targets,
            count: Some(count),
            interval,
            timeout,
            payload_size,
            duration: None,
        }
    }
}
