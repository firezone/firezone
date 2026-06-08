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
mod portal;
mod tcp;
mod turn;
mod util;
mod websocket;

use crate::config::{HttpConfig, TcpConfig, TestType, TurnConfig, WebsocketConfig};
use anyhow::Context as _;
use clap::{Parser, Subcommand};
use config::LoadTestConfig;
use rand::rngs::StdRng;
use rand::seq::SliceRandom;
use rand::{Rng as _, SeedableRng as _};
use serde::Serialize;
use std::path::{Path, PathBuf};
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
    /// TURN relay load testing
    Turn(turn::Args),
}

#[tokio::main]
async fn main() {
    init_logging();

    // `reqwest` is built with `rustls-no-provider`, so no crypto provider is
    // installed automatically. Install `ring` explicitly before any TLS is used.
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

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

    // Resolve the config (optional in subcommand mode) and seed once, then
    // dispatch: `random` selects from the config, while each subcommand resolves
    // its matching section as a base that explicitly-passed CLI args override.
    let config = load_optional_config(cli.config.as_deref())?;
    let mut selector = TestSelector::new(cli.seed);
    let seed = selector.seed();

    match cli.command {
        None | Some(Commands::Random) => run_random(config, &mut selector, seed).await?,
        Some(Commands::Http(args)) => {
            let base = config
                .as_ref()
                .and_then(|c| c.http.as_ref())
                .map(|s| selector.resolve_http(s));
            http::run_with_args(args, base, seed).await?;
        }
        Some(Commands::Tcp(args)) => {
            let base = config
                .as_ref()
                .and_then(|c| c.tcp.as_ref())
                .map(|s| selector.resolve_tcp(s));
            tcp::run_with_args(args, base, seed).await?;
        }
        Some(Commands::Websocket(args)) => {
            let base = config
                .as_ref()
                .and_then(|c| c.websocket.as_ref())
                .map(|s| selector.resolve_websocket(s));
            websocket::run_with_args(args, base, seed).await?;
        }
        Some(Commands::Turn(args)) => {
            let base = config
                .as_ref()
                .and_then(|c| c.turn.as_ref())
                .map(resolve_turn);
            turn::run_with_args(args, base, seed).await?;
        }
    }

    Ok(())
}

/// Load the config for subcommand mode, where it is optional.
///
/// An explicitly-specified `--config` must exist; the default file is used only
/// if it happens to be present.
fn load_optional_config(explicit: Option<&Path>) -> anyhow::Result<Option<LoadTestConfig>> {
    match explicit {
        Some(path) => Ok(Some(LoadTestConfig::load(path)?)),
        None => {
            let default = Path::new(DEFAULT_CONFIG_FILE);

            if default.exists() {
                Ok(Some(LoadTestConfig::load(default)?))
            } else {
                Ok(None)
            }
        }
    }
}

/// Default configuration compiled from the example file.
const DEFAULT_CONFIG: &str = include_str!("../loadtest.example.toml");

/// Run a random test selected from the config.
///
/// Unlike subcommand mode, a config is required here: there is nothing to select
/// from otherwise.
async fn run_random(
    config: Option<LoadTestConfig>,
    selector: &mut TestSelector,
    seed: u64,
) -> anyhow::Result<()> {
    let config = config.context(
        "No config file found; create a loadtest.toml file or specify one with --config",
    )?;

    let enabled_types = config.enabled_types();
    anyhow::ensure!(
        !enabled_types.is_empty(),
        "No test sections configured; add at least one of [http], [tcp], [websocket] or [turn]"
    );

    tracing::info!(seed, ?enabled_types, "Selecting random test");

    match selector.select(&config) {
        AnyTestConfig::Http(http) => http::run_with_config(http, seed).await,
        AnyTestConfig::Tcp(tcp) => tcp::run_with_config(tcp, seed).await,
        AnyTestConfig::Websocket(ws) => websocket::run_with_config(ws, seed).await,
        AnyTestConfig::Turn(turn) => turn::run_with_config(turn, seed).await,
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
    Turn(turn::TestConfig),
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
            TestType::Http => AnyTestConfig::Http(
                self.resolve_http(config.http.as_ref().expect("http section is present")),
            ),
            TestType::Tcp => AnyTestConfig::Tcp(
                self.resolve_tcp(config.tcp.as_ref().expect("tcp section is present")),
            ),
            TestType::Websocket => AnyTestConfig::Websocket(
                self.resolve_websocket(
                    config
                        .websocket
                        .as_ref()
                        .expect("websocket section is present"),
                ),
            ),
            TestType::Turn => AnyTestConfig::Turn(resolve_turn(
                config.turn.as_ref().expect("turn section is present"),
            )),
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

        websocket::TestConfig {
            url: address,
            concurrent,
            hold_duration: duration,
            max_echo_interval: Duration::from_secs(config.max_echo_interval_secs),
        }
    }
}

/// Resolve a TURN test configuration.
///
/// A TURN test targets a single relay with fixed parameters, so there is nothing
/// to randomize.
fn resolve_turn(config: &TurnConfig) -> turn::TestConfig {
    turn::TestConfig {
        server: config.address,
        username: config.username.clone(),
        password: config.password.clone(),
        payload_size: config.payload_size,
        bitrate_bps: config.bitrate_bps,
        duration: Duration::from_secs(config.duration_secs),
        max_loss_percent: config.max_loss_percent,
    }
}
