//! WebSocket connection load testing.
//!
//! Tests WebSocket connection establishment and hold time.
//! Optionally verifies echo responses when connected to an echo server.

use crate::DEFAULT_ECHO_PAYLOAD_SIZE;
use anyhow::{Context, Result};
use clap::Parser;
use futures::{SinkExt, StreamExt};
use rand::{Rng, RngCore};
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
use tracing::Instrument;
use url::Url;

/// Configuration for WebSocket load testing.
#[derive(Debug, Clone)]
pub struct TestConfig {
    /// WebSocket URL (ws:// or wss://)
    pub url: Url,
    /// Number of concurrent connections to establish
    pub concurrent: usize,
    /// How long to hold each connection open
    pub hold_duration: Duration,
    /// Connection timeout
    pub connect_timeout: Duration,
    /// Interval between ping messages (None = no pings). Ignored in echo mode.
    pub ping_interval: Option<Duration>,
    /// Enable echo mode: send timestamped payloads and verify responses
    pub echo_mode: bool,
    /// Size of echo payload in bytes (minimum 16 for header)
    pub echo_payload_size: usize,
    /// Interval between echo messages during hold period
    pub echo_interval: Option<Duration>,
    /// Timeout for reading echo responses
    pub echo_read_timeout: Duration,
}

#[derive(Parser)]
pub struct Args {
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
    #[arg(short = 'd', long, default_value = "30s", value_parser = crate::cli::parse_duration)]
    duration: Duration,

    /// Connection timeout for establishing connections
    #[arg(long, default_value = "10s", value_parser = crate::cli::parse_duration)]
    timeout: Duration,

    /// Interval between ping messages to keep connection alive (e.g., 5s). Ignored in echo mode.
    #[arg(long, value_parser = crate::cli::parse_duration)]
    ping_interval: Option<Duration>,

    /// Enable echo mode: send timestamped payloads and verify responses
    #[arg(long)]
    echo: bool,

    /// Echo payload size in bytes (minimum 16 for header)
    #[arg(long, default_value_t = DEFAULT_ECHO_PAYLOAD_SIZE, value_parser = crate::cli::parse_echo_payload_size)]
    echo_payload_size: usize,

    /// Interval between echo messages (e.g., 1s, 500ms)
    #[arg(long, value_parser = crate::cli::parse_duration)]
    echo_interval: Option<Duration>,

    /// Timeout for reading echo responses (e.g., 5s)
    #[arg(long, default_value = "5s", value_parser = crate::cli::parse_duration)]
    echo_read_timeout: Duration,
}

/// Run WebSocket test with manual CLI args.
pub async fn run_with_cli_args(args: Args) -> anyhow::Result<()> {
    if args.server {
        // Server mode
        let config = WebsocketServerConfig { port: args.port };
        run_server(config).await?;
    } else {
        // Client mode
        let url = args.url.ok_or_else(|| {
            anyhow::anyhow!("--url is required in client mode (or use --server for server mode)")
        })?;

        let config = TestConfig {
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

        run(config, 0).await?;
    }

    Ok(())
}

/// Run WebSocket test from resolved config.
pub async fn run_with_config(config: TestConfig, seed: u64) -> anyhow::Result<()> {
    run(config, seed).await?;

    Ok(())
}

/// Run the WebSocket connection load test.
///
/// Establishes `concurrent` connections and holds each open for `hold_duration`.
/// In echo mode, sends timestamped payloads and verifies responses.
/// Otherwise, optionally sends periodic ping messages to keep connections alive.
async fn run(config: TestConfig, seed: u64) -> Result<()> {
    if config.echo_mode && config.ping_interval.is_some() {
        tracing::warn!("ping_interval is ignored when echo_mode is enabled");
    }

    tracing::info!(
        url = %config.url,
        concurrent = config.concurrent,
        hold_duration = ?config.hold_duration,
        echo_mode = config.echo_mode,
        %seed,
        "Starting WebSocket connection test"
    );

    let mut connections = tokio::task::JoinSet::new();

    // Spawn one task per concurrent connection
    for id in 0..config.concurrent {
        connections.spawn(
            run_single_connection(config.clone())
                .instrument(tracing::info_span!("connection", %id)),
        );
    }

    connections
        .join_all()
        .await
        .into_iter()
        .collect::<Result<Vec<_>>>()?;

    tracing::info!("WebSocket connection test complete");

    Ok(())
}

/// Run a single WebSocket connection test.
async fn run_single_connection(config: TestConfig) -> Result<()> {
    let connect_start = Instant::now();

    let (ws, _response) = timeout(config.connect_timeout, connect_async(config.url.as_str()))
        .await
        .context("Connection timed out")?
        .context("Connection failed")?;

    let connect_latency = connect_start.elapsed();
    tracing::debug!(?connect_latency, "WebSocket connection established");

    if config.echo_mode {
        run_echo_loop(ws, &config).await?
    } else {
        run_ping_loop(ws, &config).await?;
    };

    tracing::debug!("WebSocket connection closed");

    Ok(())
}

/// Run the ping/pong loop for a connection (non-echo mode).
async fn run_ping_loop(
    mut ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    config: &TestConfig,
) -> Result<()> {
    let hold_start = Instant::now();

    if let Some(interval) = config.ping_interval {
        // Send periodic pings while holding
        while hold_start.elapsed() < config.hold_duration {
            ws.send(Message::Ping(vec![].into()))
                .await
                .context("Failed to sent ping")?;

            tracing::trace!("Sent ping");

            // Wait for pong or timeout
            #[expect(
                clippy::wildcard_enum_match_arm,
                reason = "We only care about `Pong` messages"
            )]
            match timeout(interval, ws.next())
                .await
                .context("Missing pong")?
                .context("WebSocket stream closed")?
                .context("Failed to receive message")?
            {
                Message::Pong(_) => tracing::trace!("Received pong"),
                other => anyhow::bail!("Unexpected message: {other:?}"),
            }

            tokio::time::sleep(interval).await;
        }
    } else {
        // Just sleep without sending messages
        tokio::time::sleep(config.hold_duration).await;
    }

    ws.close(None).await.context("Failed to close connection")?;

    Ok(())
}

/// Run the echo verification loop for a connection.
async fn run_echo_loop(
    mut ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    config: &TestConfig,
) -> Result<()> {
    let hold_start = Instant::now();
    let echo_interval = config.echo_interval.unwrap_or(Duration::from_secs(1));

    while hold_start.elapsed() < config.hold_duration {
        let payload_size = rand::thread_rng().gen_range(0..config.echo_payload_size);
        let mut buffer = vec![0u8; payload_size];
        rand::thread_rng().fill_bytes(&mut buffer);

        ws.send(Message::Binary(buffer.clone().into()))
            .await
            .context("Failed to send echo payload")?;

        tracing::trace!(len = %buffer.len(), "Sent binary message");

        // Read response with timeout
        match timeout(config.echo_read_timeout, ws.next())
            .await
            .context("Echo response timed out")?
            .context("WebSocket connection closed")?
            .context("Failed to read WebSocket message")?
        {
            Message::Binary(data) => {
                tracing::trace!("Received binary message");

                anyhow::ensure!(data == buffer, "Echo response does not match");
            }
            Message::Text(_) => anyhow::bail!("Unexpected `Text` message"),
            Message::Close(_) => anyhow::bail!("WebSocket closed by server"),
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
        }

        // Wait for next interval (if we haven't exceeded hold duration)
        let remaining = config.hold_duration.saturating_sub(hold_start.elapsed());
        if remaining > Duration::ZERO && remaining > echo_interval {
            tokio::time::sleep(echo_interval).await;
        } else if remaining > Duration::ZERO {
            tokio::time::sleep(remaining).await;
        }
    }

    // Graceful close
    ws.close(None).await?;

    Ok(())
}

/// Configuration for WebSocket echo server.
#[derive(Debug, Clone)]
pub struct WebsocketServerConfig {
    /// Port to listen on.
    pub port: u16,
}

/// Run a WebSocket echo server.
///
/// Listens for WebSocket connections and echoes back any received messages.
/// Runs indefinitely until interrupted.
async fn run_server(config: WebsocketServerConfig) -> anyhow::Result<()> {
    use axum::{
        Router,
        extract::ws::{Message as AxumMessage, WebSocket, WebSocketUpgrade},
        response::IntoResponse,
        routing::get,
    };
    use std::net::Ipv4Addr;
    use tokio::net::TcpListener;

    async fn ws_handler(ws: WebSocketUpgrade) -> impl IntoResponse {
        ws.on_upgrade(handle_ws_connection)
    }

    async fn handle_ws_connection(mut socket: WebSocket) {
        while let Some(msg) = socket.recv().await {
            match msg {
                Ok(AxumMessage::Text(text)) => {
                    tracing::trace!(len = text.len(), "WebSocket text received");
                    if socket.send(AxumMessage::Text(text)).await.is_err() {
                        break;
                    }
                }
                Ok(AxumMessage::Binary(data)) => {
                    tracing::trace!(len = data.len(), "WebSocket binary received");
                    if socket.send(AxumMessage::Binary(data)).await.is_err() {
                        break;
                    }
                }
                Ok(AxumMessage::Ping(data)) => {
                    tracing::trace!("WebSocket ping received");
                    if socket.send(AxumMessage::Pong(data)).await.is_err() {
                        break;
                    }
                }
                Ok(AxumMessage::Pong(_)) => {
                    // Ignore pongs
                }
                Ok(AxumMessage::Close(_)) => {
                    tracing::trace!("WebSocket close received");
                    break;
                }
                Err(e) => {
                    tracing::debug!(error = %e, "WebSocket error");
                    break;
                }
            }
        }
        tracing::trace!("WebSocket connection closed");
    }

    let router = Router::new().route("/", get(ws_handler));
    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, config.port)).await?;
    tracing::info!(port = config.port, "WebSocket echo server listening");

    axum::serve(listener, router).await?;

    Ok(())
}
