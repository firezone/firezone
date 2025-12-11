//! TCP connection load testing.
//!
//! Tests raw TCP connection establishment and hold time.
//! Optionally verifies echo responses when connected to an echo server.

use crate::echo_payload::{self, EchoPayload};
use crate::util::{EchoStats, StreamingStats, saturating_usize_to_u32};
use crate::{DEFAULT_ECHO_PAYLOAD_SIZE, WithSeed};
use anyhow::Result;
use clap::Parser;
use serde::Serialize;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::time::timeout;
use tracing::{debug, info, trace, warn};

/// Configuration for TCP connection load testing.
#[derive(Debug, Clone)]
pub struct TestConfig {
    /// Target address
    pub target: String,
    /// Number of concurrent connections to establish
    pub concurrent: usize,
    /// How long to hold each connection open
    pub hold_duration: Duration,
    /// Connection timeout
    pub connect_timeout: Duration,
    /// Enable echo mode: send timestamped payloads and verify responses
    pub echo_mode: bool,
    /// Size of echo payload in bytes (minimum 16 for header)
    pub echo_payload_size: usize,
    /// Interval between echo messages during hold period
    pub echo_interval: Option<Duration>,
    /// Timeout for reading echo responses
    pub echo_read_timeout: Duration,
}

/// Result of a single TCP connection attempt.
struct ConnectionResult {
    success: bool,
    /// Time to establish connection
    connect_latency: Duration,
    /// How long the connection was held open (if successful)
    held_duration: Duration,
    /// Echo mode statistics
    echo_stats: EchoStats,
}

/// Summary of TCP load test results.
///
/// # Echo Mode Semantics
///
/// When `echo_mode` is `true`, the `failed_connections` count includes connections
/// that had any echo verification failures (mismatches), not just connection failures.
/// A connection is considered successful only if it both connected successfully AND
/// had zero echo mismatches during the test duration.
#[derive(Debug, Serialize)]
pub struct TcpTestSummary {
    pub test_type: &'static str,
    pub target: String,
    pub concurrent_connections: usize,
    pub hold_duration_secs: u64,
    pub total_connections: usize,
    pub successful_connections: usize,
    pub failed_connections: usize,
    /// Peak number of connections that were simultaneously active.
    pub peak_active_connections: usize,
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

#[derive(Parser)]
pub struct Args {
    /// Run as echo server (listen for connections)
    #[arg(long)]
    server: bool,

    /// Port to listen on (server mode only)
    #[arg(short = 'p', long, default_value = "9000")]
    port: u16,

    /// Target address (host:port) - required in client mode
    #[arg(long, value_name = "ADDR")]
    target: Option<String>,

    /// Number of concurrent connections to establish
    #[arg(short = 'c', long, default_value = "10")]
    concurrent: usize,

    /// How long to hold each connection open (e.g., 30s, 5m)
    #[arg(short = 'd', long, default_value = "30s", value_parser = crate::cli::parse_duration)]
    duration: Duration,

    /// Connection timeout for establishing connections
    #[arg(long, default_value = "10s", value_parser = crate::cli::parse_duration)]
    timeout: Duration,

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

/// Run TCP test with manual CLI args.
pub async fn run_with_cli_args(args: Args) -> anyhow::Result<()> {
    if args.server {
        // Server mode
        let config = TcpServerConfig { port: args.port };
        run_server(config).await?;
    } else {
        // Client mode
        let target = args.target.ok_or_else(|| {
            anyhow::anyhow!("--target is required in client mode (or use --server for server mode)")
        })?;

        let config = TestConfig {
            target,
            concurrent: args.concurrent,
            hold_duration: args.duration,
            connect_timeout: args.timeout,
            echo_mode: args.echo,
            echo_payload_size: args.echo_payload_size,
            echo_interval: args.echo_interval,
            echo_read_timeout: args.echo_read_timeout,
        };

        let summary = run(config).await?;

        println!(
            "{}",
            serde_json::to_string(&summary).expect("Failed to serialize metrics")
        );
    }

    Ok(())
}

/// Run TCP test from resolved config.
pub async fn run_with_config(config: TestConfig, seed: u64) -> anyhow::Result<()> {
    let summary = run(config).await?;

    println!(
        "{}",
        serde_json::to_string(&WithSeed::new(seed, summary)).expect("Failed to serialize metrics")
    );

    Ok(())
}

async fn run(config: TestConfig) -> Result<TcpTestSummary> {
    let (tx, mut rx) = mpsc::channel::<ConnectionResult>(config.concurrent);
    let active_connections = Arc::new(AtomicUsize::new(0));
    let peak_active = Arc::new(AtomicUsize::new(0));

    info!(
        target = %config.target,
        concurrent = config.concurrent,
        hold_duration = ?config.hold_duration,
        echo_mode = config.echo_mode,
        "Starting TCP connection test"
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
        avg_connect_latency_ms = avg_latency.as_millis(),
        echo_verified = total_echo_verified,
        echo_mismatches = total_echo_mismatches,
        "TCP connection test complete"
    );

    let summary = TcpTestSummary {
        test_type: "tcp",
        target: config.target.to_string(),
        concurrent_connections: config.concurrent,
        hold_duration_secs: config.hold_duration.as_secs(),
        total_connections: total,
        successful_connections: successful,
        failed_connections: failed,
        peak_active_connections: peak_active.load(Ordering::SeqCst),
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
    };

    Ok(summary)
}

/// Run a single TCP connection test.
async fn run_single_connection(
    connection_id: usize,
    config: &TestConfig,
    active: &AtomicUsize,
    peak: &AtomicUsize,
) -> ConnectionResult {
    let connect_start = Instant::now();

    match timeout(config.connect_timeout, TcpStream::connect(&config.target)).await {
        Ok(Ok(stream)) => {
            let connect_latency = connect_start.elapsed();
            let current = active.fetch_add(1, Ordering::SeqCst) + 1;
            // Update peak if this is a new high water mark
            peak.fetch_max(current, Ordering::SeqCst);
            trace!(connection = connection_id, target = %config.target, ?connect_latency, "TCP connection established");

            let hold_start = Instant::now();
            let echo_stats = if config.echo_mode {
                run_echo_loop(connection_id, stream, config).await
            } else {
                // Just hold the connection open
                tokio::time::sleep(config.hold_duration).await;
                EchoStats::default()
            };
            let held_duration = hold_start.elapsed();

            active.fetch_sub(1, Ordering::SeqCst);
            trace!(connection = connection_id, target = %config.target, ?held_duration, "TCP connection closed");

            // A connection is only successful if there were no echo mismatches
            let success = echo_stats.mismatches == 0;

            ConnectionResult {
                success,
                connect_latency,
                held_duration,
                echo_stats,
            }
        }
        Ok(Err(e)) => {
            debug!(connection = connection_id, target = %config.target, error = %e, "TCP connection failed");
            ConnectionResult {
                success: false,
                connect_latency: connect_start.elapsed(),
                held_duration: Duration::ZERO,
                echo_stats: EchoStats::default(),
            }
        }
        Err(_) => {
            debug!(connection = connection_id, target = %config.target, "TCP connection timed out");
            ConnectionResult {
                success: false,
                connect_latency: connect_start.elapsed(),
                held_duration: Duration::ZERO,
                echo_stats: EchoStats::default(),
            }
        }
    }
}

/// Run the echo verification loop for a connection.
async fn run_echo_loop(
    connection_id: usize,
    mut stream: TcpStream,
    config: &TestConfig,
) -> EchoStats {
    let mut stats = EchoStats::default();
    let hold_start = Instant::now();
    let echo_interval = config.echo_interval.unwrap_or(Duration::from_secs(1));

    while hold_start.elapsed() < config.hold_duration {
        // Create and send payload
        let payload = EchoPayload::new(connection_id as u64, config.echo_payload_size);
        let bytes = payload.to_bytes();

        if let Err(e) = stream.write_all(&bytes).await {
            warn!(connection = connection_id, error = %e, "Failed to send echo payload");
            stats.mismatches += 1;
            break;
        }
        if let Err(e) = stream.flush().await {
            warn!(connection = connection_id, error = %e, "Failed to flush echo payload");
            stats.mismatches += 1;
            break;
        }
        stats.messages_sent += 1;

        // Read response with timeout
        let mut response = vec![0u8; bytes.len()];
        match timeout(config.echo_read_timeout, stream.read_exact(&mut response)).await {
            Ok(Ok(_)) => match echo_payload::verify_echo(&payload, &response) {
                Ok(received) => {
                    stats.messages_verified += 1;
                    if let Some(latency) = received.round_trip_latency() {
                        stats.latencies.record(latency);
                        trace!(
                            connection = connection_id,
                            latency_ms = latency.as_millis(),
                            "Echo verified"
                        );
                    }
                }
                Err(e) => {
                    warn!(connection = connection_id, error = %e, "Echo verification failed");
                    stats.mismatches += 1;
                }
            },
            Ok(Err(e)) => {
                warn!(connection = connection_id, error = %e, "Failed to read echo response");
                stats.mismatches += 1;
                break;
            }
            Err(_) => {
                warn!(connection = connection_id, "Echo response timed out");
                stats.mismatches += 1;
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

    stats
}

/// Configuration for TCP echo server.
#[derive(Debug, Clone)]
pub struct TcpServerConfig {
    /// Port to listen on.
    pub port: u16,
}

/// Run a TCP echo server.
///
/// Listens for connections and echoes back any received data.
/// Runs indefinitely until interrupted.
async fn run_server(config: TcpServerConfig) -> anyhow::Result<()> {
    use std::net::Ipv4Addr;
    use tokio::net::TcpListener;

    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, config.port)).await?;
    info!(port = config.port, "TCP echo server listening");

    loop {
        let (stream, addr) = listener.accept().await?;
        debug!(%addr, "TCP connection accepted");

        tokio::spawn(async move {
            if let Err(e) = handle_echo_connection(stream).await {
                debug!(%addr, error = %e, "TCP connection error");
            }
            trace!(%addr, "TCP connection closed");
        });
    }
}

/// Handle a single TCP connection by echoing all received data.
async fn handle_echo_connection(mut stream: TcpStream) -> anyhow::Result<()> {
    let mut buf = [0u8; 8192];

    loop {
        let n = stream.read(&mut buf).await?;
        if n == 0 {
            // Connection closed
            break;
        }

        stream.write_all(&buf[..n]).await?;
        stream.flush().await?;
        trace!(bytes = n, "TCP echoed");
    }

    Ok(())
}
