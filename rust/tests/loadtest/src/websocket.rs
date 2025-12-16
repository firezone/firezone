use anyhow::{Context, Result};
use clap::Parser;
use futures::{SinkExt, StreamExt};
use rand::{Rng, RngCore, SeedableRng};
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
use tracing::Instrument;
use url::Url;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const REPLY_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_PAYLOAD_SIZE: usize = u16::MAX as usize; // Big enough to definitely spread across multiple IP packets but also small to not consume too many resources.

/// Configuration for WebSocket load testing.
#[derive(Debug, Clone)]
pub struct TestConfig {
    /// WebSocket URL (ws:// or wss://)
    pub url: Url,
    /// Number of concurrent connections to establish
    pub concurrent: usize,
    /// How long to hold each connection open
    pub hold_duration: Duration,
    /// How long to at most wait between messages. Zero means we won't send any messages.
    pub max_echo_interval: Duration,
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

    /// How long to at most wait between messages. Zero means we won't send any messages.
    #[arg(long, value_parser = crate::cli::parse_duration)]
    max_echo_interval: Option<Duration>,
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
            max_echo_interval: args.max_echo_interval.unwrap_or_default(),
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

/// Sends random binary data over each connection and verifies echo responses.
async fn run(config: TestConfig, seed: u64) -> Result<()> {
    tracing::info!(
        url = %config.url,
        concurrent = config.concurrent,
        hold_duration = ?config.hold_duration,
        %seed,
        "Starting WebSocket connection test"
    );

    let mut connections = tokio::task::JoinSet::new();

    // Spawn one task per concurrent connection
    for id in 0..config.concurrent {
        connections.spawn(
            run_single_connection(config.clone(), seed + id as u64)
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
async fn run_single_connection(config: TestConfig, seed: u64) -> Result<()> {
    let connect_start = Instant::now();

    let (ws, _response) = timeout(CONNECT_TIMEOUT, connect_async(config.url.as_str()))
        .await
        .context("Connection timed out")?
        .context("Connection failed")?;

    let connect_latency = connect_start.elapsed();
    tracing::debug!(?connect_latency, "WebSocket connection established");

    run_echo_loop(ws, &config, seed).await?;

    tracing::debug!("WebSocket connection closed");

    Ok(())
}

/// Run the echo verification loop for a connection.
async fn run_echo_loop(
    mut ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    config: &TestConfig,
    seed: u64,
) -> Result<()> {
    if config.max_echo_interval.is_zero() {
        tokio::time::sleep(config.hold_duration).await;
        return Ok(());
    }

    let mut rng = rand::rngs::StdRng::seed_from_u64(seed);

    let hold_start = Instant::now();

    while hold_start.elapsed() < config.hold_duration {
        let payload_size = rng.gen_range(0..MAX_PAYLOAD_SIZE);
        let mut buffer = vec![0u8; payload_size];
        rng.fill_bytes(&mut buffer);

        ws.send(Message::Binary(buffer.clone().into()))
            .await
            .context("Failed to send echo payload")?;

        tracing::trace!(len = %buffer.len(), "Sent binary message");

        // Read response with timeout
        match timeout(REPLY_TIMEOUT, ws.next())
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

        let interval = rng.gen_range(Duration::ZERO..config.max_echo_interval);

        tracing::trace!("Next message in {interval:?}");

        tokio::time::sleep(interval).await;
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
