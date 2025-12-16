//! WebSocket connection load testing.
//!
//! Tests WebSocket connection establishment and hold time.
//! Optionally verifies echo responses when connected to an echo server.

use crate::echo_payload::{self, EchoPayload};
use crate::util::{EchoStats, StreamingStats, saturating_usize_to_u32};
use crate::{DEFAULT_ECHO_PAYLOAD_SIZE, WithSeed};
use anyhow::Result;
use clap::Parser;
use futures::{SinkExt, StreamExt};
use serde::Serialize;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
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

/// Result of a WebSocket connection attempt.
struct ConnectionResult {
    success: bool,
    messages_sent: usize,
    messages_received: usize,
    connect_latency: Duration,
    held_duration: Duration,
    /// Echo mode statistics
    echo_stats: EchoStats,
}

/// Summary of WebSocket load test results.
///
/// # Echo Mode Semantics
///
/// When `echo_mode` is `true`, the `failed_connections` count includes connections
/// that had any echo verification failures (mismatches), not just connection failures.
/// A connection is considered successful only if it both connected successfully AND
/// had zero echo mismatches during the test duration.
#[derive(Debug, Serialize)]
pub struct WebsocketTestSummary {
    pub test_type: &'static str,
    pub url: String,
    pub concurrent_connections: usize,
    pub hold_duration_secs: u64,
    pub total_connections: usize,
    pub successful_connections: usize,
    pub failed_connections: usize,
    /// Peak number of connections that were simultaneously active.
    pub peak_active_connections: usize,
    pub total_messages_sent: usize,
    pub total_messages_received: usize,
    pub min_connect_latency_ms: u64,
    pub max_connect_latency_ms: u64,
    pub avg_connect_latency_ms: u64,
    pub avg_held_duration_ms: u64,
    // Echo mode fields
    pub echo_mode: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub echo_messages_sent: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub echo_messages_verified: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub echo_mismatches: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_echo_latency_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_echo_latency_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avg_echo_latency_ms: Option<u64>,
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

        let summary = run(config, 0).await?;
        println!(
            "{}",
            serde_json::to_string(&summary).expect("Failed to serialize metrics")
        );
    }

    Ok(())
}

/// Run WebSocket test from resolved config.
pub async fn run_with_config(config: TestConfig, seed: u64) -> anyhow::Result<()> {
    let summary = run(config, seed).await?;

    println!(
        "{}",
        serde_json::to_string(&WithSeed::new(seed, summary)).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Run the WebSocket connection load test.
///
/// Establishes `concurrent` connections and holds each open for `hold_duration`.
/// In echo mode, sends timestamped payloads and verifies responses.
/// Otherwise, optionally sends periodic ping messages to keep connections alive.
async fn run(config: TestConfig, seed: u64) -> Result<WebsocketTestSummary> {
    let (tx, mut rx) = mpsc::channel::<ConnectionResult>(config.concurrent);
    let active_connections = Arc::new(AtomicUsize::new(0));
    let peak_active = Arc::new(AtomicUsize::new(0));

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

    // Spawn one task per concurrent connection
    for i in 0..config.concurrent {
        let tx = tx.clone();
        let config = config.clone();
        let active = Arc::clone(&active_connections);
        let peak = Arc::clone(&peak_active);

        tokio::spawn(async move {
            let result = run_single_connection(i, &config, &active, &peak).await;
            let _ = tx.send(result).await;
        });
    }

    // Drop our sender so rx completes when all workers finish
    drop(tx);

    // Collect results
    let mut total = 0usize;
    let mut successful = 0usize;
    let mut failed = 0usize;
    let mut total_sent = 0usize;
    let mut total_received = 0usize;
    let mut min_latency = Duration::MAX;
    let mut max_latency = Duration::ZERO;
    let mut total_latency = Duration::ZERO;
    let mut total_held = Duration::ZERO;

    // Echo mode aggregates
    let mut total_echo_sent = 0usize;
    let mut total_echo_verified = 0usize;
    let mut total_echo_mismatches = 0usize;
    let mut echo_latencies = StreamingStats::new();

    while let Some(result) = rx.recv().await {
        total += 1;
        if result.success {
            successful += 1;
            total_sent += result.messages_sent;
            total_received += result.messages_received;
            min_latency = min_latency.min(result.connect_latency);
            max_latency = max_latency.max(result.connect_latency);
            total_latency += result.connect_latency;
            total_held += result.held_duration;

            // Aggregate echo stats
            total_echo_sent += result.echo_stats.messages_sent;
            total_echo_verified += result.echo_stats.messages_verified;
            total_echo_mismatches += result.echo_stats.mismatches;
            echo_latencies.merge(&result.echo_stats.latencies);
        } else {
            failed += 1;
        }
    }

    let avg_latency = if successful > 0 {
        total_latency / saturating_usize_to_u32(successful)
    } else {
        Duration::ZERO
    };

    let avg_held = if successful > 0 {
        total_held / saturating_usize_to_u32(successful)
    } else {
        Duration::ZERO
    };

    // Calculate echo latency stats
    let (min_echo_latency, max_echo_latency, avg_echo_latency) =
        if config.echo_mode && echo_latencies.count() > 0 {
            (
                echo_latencies.min().map(|d| d.as_millis() as u64),
                echo_latencies.max().map(|d| d.as_millis() as u64),
                echo_latencies.avg().map(|d| d.as_millis() as u64),
            )
        } else {
            (None, None, None)
        };

    let has_errors = failed > 0 || total_echo_mismatches > 0;
    crate::log_test_result!(
        has_errors,
        successful,
        failed,
        total_sent,
        total_received,
        avg_connect_latency_ms = avg_latency.as_millis(),
        echo_verified = total_echo_verified,
        echo_mismatches = total_echo_mismatches,
        "WebSocket connection test complete"
    );

    Ok(WebsocketTestSummary {
        test_type: "websocket",
        url: config.url.to_string(),
        concurrent_connections: config.concurrent,
        hold_duration_secs: config.hold_duration.as_secs(),
        total_connections: total,
        successful_connections: successful,
        failed_connections: failed,
        peak_active_connections: peak_active.load(Ordering::SeqCst),
        total_messages_sent: total_sent,
        total_messages_received: total_received,
        min_connect_latency_ms: if min_latency == Duration::MAX {
            0
        } else {
            min_latency.as_millis() as u64
        },
        max_connect_latency_ms: max_latency.as_millis() as u64,
        avg_connect_latency_ms: avg_latency.as_millis() as u64,
        avg_held_duration_ms: avg_held.as_millis() as u64,
        echo_mode: config.echo_mode,
        echo_messages_sent: config.echo_mode.then_some(total_echo_sent),
        echo_messages_verified: config.echo_mode.then_some(total_echo_verified),
        echo_mismatches: config.echo_mode.then_some(total_echo_mismatches),
        min_echo_latency_ms: min_echo_latency,
        max_echo_latency_ms: max_echo_latency,
        avg_echo_latency_ms: avg_echo_latency,
    })
}

/// Run a single WebSocket connection test.
async fn run_single_connection(
    connection_id: usize,
    config: &TestConfig,
    active: &AtomicUsize,
    peak: &AtomicUsize,
) -> ConnectionResult {
    let connect_start = Instant::now();

    match timeout(config.connect_timeout, connect_async(config.url.as_str())).await {
        Ok(Ok((ws, _response))) => {
            let connect_latency = connect_start.elapsed();
            let current = active.fetch_add(1, Ordering::SeqCst) + 1;
            // Update peak if this is a new high water mark
            peak.fetch_max(current, Ordering::SeqCst);
            tracing::trace!(connection = connection_id, url = %config.url, ?connect_latency, "WebSocket connection established");

            let hold_start = Instant::now();

            let (messages_sent, messages_received, echo_stats) = if config.echo_mode {
                let stats = run_echo_loop(connection_id, ws, config).await;
                (stats.messages_sent, stats.messages_verified, stats)
            } else {
                let (sent, received) = run_ping_loop(connection_id, ws, config).await;
                (sent, received, EchoStats::default())
            };

            let held_duration = hold_start.elapsed();
            active.fetch_sub(1, Ordering::SeqCst);
            tracing::trace!(connection = connection_id, url = %config.url, ?held_duration, "WebSocket connection closed");

            // A connection is only successful if there were no echo mismatches
            let success = echo_stats.mismatches == 0;

            ConnectionResult {
                success,
                messages_sent,
                messages_received,
                connect_latency,
                held_duration,
                echo_stats,
            }
        }
        Ok(Err(e)) => {
            tracing::debug!(connection = connection_id, url = %config.url, error = %e, "WebSocket connection failed");
            ConnectionResult {
                success: false,
                messages_sent: 0,
                messages_received: 0,
                connect_latency: connect_start.elapsed(),
                held_duration: Duration::ZERO,
                echo_stats: EchoStats::default(),
            }
        }
        Err(_) => {
            tracing::debug!(connection = connection_id, url = %config.url, "WebSocket connection timed out");
            ConnectionResult {
                success: false,
                messages_sent: 0,
                messages_received: 0,
                connect_latency: connect_start.elapsed(),
                held_duration: Duration::ZERO,
                echo_stats: EchoStats::default(),
            }
        }
    }
}

/// Run the ping/pong loop for a connection (non-echo mode).
async fn run_ping_loop(
    connection_id: usize,
    mut ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    config: &TestConfig,
) -> (usize, usize) {
    let mut sent = 0usize;
    let mut received = 0usize;
    let hold_start = Instant::now();

    if let Some(interval) = config.ping_interval {
        // Send periodic pings while holding
        while hold_start.elapsed() < config.hold_duration {
            if ws.send(Message::Ping(vec![].into())).await.is_ok() {
                sent += 1;
                tracing::trace!(connection = connection_id, "Sent ping");
            }
            // Wait for pong or timeout
            match timeout(interval, ws.next()).await {
                Ok(Some(Ok(Message::Pong(_)))) => {
                    received += 1;
                    tracing::trace!(connection = connection_id, "Received pong");
                }
                Ok(Some(Ok(_))) => {
                    // Other message type, still counts as received
                    received += 1;
                }
                Ok(Some(Err(e))) => {
                    tracing::debug!(connection = connection_id, error = %e, "WebSocket error during hold");
                    break;
                }
                Ok(None) => {
                    tracing::debug!(connection = connection_id, "WebSocket closed by server");
                    break;
                }
                Err(_) => {
                    // Timeout waiting for pong, continue
                }
            }
            tokio::time::sleep(interval).await;
        }
    } else {
        // Just sleep without sending messages
        tokio::time::sleep(config.hold_duration).await;
    }

    // Graceful close
    let _ = ws.close(None).await;

    (sent, received)
}

/// Run the echo verification loop for a connection.
async fn run_echo_loop(
    connection_id: usize,
    mut ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    config: &TestConfig,
) -> EchoStats {
    let mut stats = EchoStats::default();
    let hold_start = Instant::now();
    let echo_interval = config.echo_interval.unwrap_or(Duration::from_secs(1));

    while hold_start.elapsed() < config.hold_duration {
        // Create and send payload as binary message
        let payload = EchoPayload::new(connection_id as u64, config.echo_payload_size);
        let bytes = payload.to_bytes();

        if let Err(e) = ws.send(Message::Binary(bytes.clone().into())).await {
            tracing::warn!(connection = connection_id, error = %e, "Failed to send echo payload");
            stats.mismatches += 1;
            break;
        }
        stats.messages_sent += 1;

        // Read response with timeout
        match timeout(config.echo_read_timeout, ws.next()).await {
            Ok(Some(Ok(Message::Binary(data)))) => {
                match echo_payload::verify_echo(&payload, &data) {
                    Ok(received) => {
                        stats.messages_verified += 1;
                        if let Some(latency) = received.round_trip_latency() {
                            stats.latencies.record(latency);
                            tracing::trace!(
                                connection = connection_id,
                                latency_ms = latency.as_millis(),
                                "Echo verified"
                            );
                        }
                    }
                    Err(e) => {
                        tracing::warn!(connection = connection_id, error = %e, "Echo verification failed");
                        stats.mismatches += 1;
                    }
                }
            }
            Ok(Some(Ok(Message::Text(text)))) => {
                // Try to verify as text (some servers echo back as text)
                match echo_payload::verify_echo(&payload, text.as_bytes()) {
                    Ok(received) => {
                        stats.messages_verified += 1;
                        if let Some(latency) = received.round_trip_latency() {
                            stats.latencies.record(latency);
                            tracing::trace!(
                                connection = connection_id,
                                latency_ms = latency.as_millis(),
                                "Echo verified (text)"
                            );
                        }
                    }
                    Err(e) => {
                        tracing::warn!(connection = connection_id, error = %e, "Echo verification failed (text response)");
                        stats.mismatches += 1;
                    }
                }
            }
            Ok(Some(Ok(Message::Ping(_)))) | Ok(Some(Ok(Message::Pong(_)))) => {
                // Ignore ping/pong, don't count as mismatch, try again
                continue;
            }
            Ok(Some(Ok(Message::Close(_)))) => {
                tracing::debug!(connection = connection_id, "WebSocket closed by server");
                stats.mismatches += 1;
                break;
            }
            Ok(Some(Err(e))) => {
                tracing::warn!(connection = connection_id, error = %e, "WebSocket error during echo");
                stats.mismatches += 1;
                break;
            }
            Ok(None) => {
                tracing::debug!(connection = connection_id, "WebSocket closed by server");
                stats.mismatches += 1;
                break;
            }
            Err(_) => {
                tracing::warn!(connection = connection_id, "Echo response timed out");
                stats.mismatches += 1;
            }
            Ok(Some(Ok(Message::Frame(_)))) => {
                // Raw frame, shouldn't normally see this
                continue;
            }
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
    let _ = ws.close(None).await;

    stats
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
