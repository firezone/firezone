//! ICMP ping load testing.
//!
//! Uses surge-ping for cross-platform ICMP echo requests.
//! Note: Requires elevated privileges on Linux/macOS (CAP_NET_RAW or root).

use crate::WithSeed;
use crate::util::StreamingStats;
use anyhow::{Context, Result, bail};
use clap::Parser;
use serde::Serialize;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use surge_ping::{Client, Config, ICMP, PingIdentifier, PingSequence};
use tokio::sync::mpsc;
use tracing::{debug, info, trace};

/// Maximum ICMP payload size in bytes.
///
/// This is derived from the maximum IP packet size (65535) minus the IP header (20 bytes)
/// and ICMP header (8 bytes). In practice, MTU limits will restrict actual payload size,
/// but we validate against the theoretical maximum to catch obvious configuration errors.
pub const MAX_ICMP_PAYLOAD_SIZE: usize = 65507;

/// Configuration for ICMP ping testing.
#[derive(Debug, Clone)]
pub struct TestConfig {
    /// Target IP addresses to ping.
    pub targets: Vec<IpAddr>,
    /// Number of pings per target.
    pub count: Option<usize>,
    /// Alternative to count: run for this duration.
    pub duration: Option<Duration>,
    /// Interval between pings.
    pub interval: Duration,
    /// Ping timeout.
    pub timeout: Duration,
    /// ICMP payload size in bytes.
    pub payload_size: usize,
}

/// Result of pings to a single target.
#[derive(Debug)]
struct TargetResult {
    target: IpAddr,
    packets_sent: usize,
    packets_received: usize,
    rtts: StreamingStats,
}

/// Per-target summary in the output.
#[derive(Debug, Serialize)]
pub struct TargetSummary {
    pub target: String,
    pub packets_sent: usize,
    pub packets_received: usize,
    pub packet_loss_percent: f64,
    pub min_rtt_ms: Option<f64>,
    pub max_rtt_ms: Option<f64>,
    pub avg_rtt_ms: Option<f64>,
}

/// Summary of ping test results.
#[derive(Debug, Serialize)]
pub struct PingTestSummary {
    pub test_type: &'static str,
    pub targets: Vec<String>,
    pub packets_sent: usize,
    pub packets_received: usize,
    pub packet_loss_percent: f64,
    pub min_rtt_ms: Option<f64>,
    pub max_rtt_ms: Option<f64>,
    pub avg_rtt_ms: Option<f64>,
    pub per_target: Vec<TargetSummary>,
}

#[derive(Parser)]
pub struct Args {
    /// Target IP address(es) to ping
    #[arg(long, value_name = "IP", required = true, num_args = 1..)]
    target: Vec<IpAddr>,

    /// Number of pings per target
    #[arg(short = 'c', long)]
    count: Option<usize>,

    /// Run for specified duration instead of count (e.g., 60s, 5m)
    #[arg(short = 't', long, value_parser = crate::cli::parse_duration, conflicts_with = "count")]
    duration: Option<Duration>,

    /// Interval between pings (e.g., 1s, 500ms)
    #[arg(short = 'i', long, default_value = "1s", value_parser = crate::cli::parse_duration)]
    interval: Duration,

    /// Ping timeout (e.g., 5s)
    #[arg(long, default_value = "5s", value_parser = crate::cli::parse_duration)]
    timeout: Duration,

    /// ICMP payload size in bytes (max 65507)
    #[arg(short = 's', long, default_value = "56", value_parser = crate::cli::parse_ping_payload_size)]
    payload_size: usize,
}

/// Run ping test with manual CLI args.
pub async fn run_with_cli_args(args: Args) -> anyhow::Result<()> {
    // Ensure at least count or duration is specified
    let (count, duration) = if args.count.is_none() && args.duration.is_none() {
        // Default to 10 pings if neither specified
        (Some(10), None)
    } else {
        (args.count, args.duration)
    };

    let config = TestConfig {
        targets: args.target,
        count,
        duration,
        interval: args.interval,
        timeout: args.timeout,
        payload_size: args.payload_size,
    };

    let summary = run(config).await?;

    println!(
        "{}",
        serde_json::to_string(&summary).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Run ping test from resolved config.
pub async fn run_with_config(config: TestConfig, seed: u64) -> anyhow::Result<()> {
    let summary = run(config).await?;

    println!(
        "{}",
        serde_json::to_string(&WithSeed::new(seed, summary)).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Run the ICMP ping test.
async fn run(config: TestConfig) -> Result<PingTestSummary> {
    // Validate payload size
    if config.payload_size > MAX_ICMP_PAYLOAD_SIZE {
        bail!(
            "Payload size {} exceeds maximum ICMP payload of {MAX_ICMP_PAYLOAD_SIZE} bytes",
            config.payload_size
        );
    }

    info!(
        targets = ?config.targets,
        count = ?config.count,
        duration = ?config.duration,
        interval = ?config.interval,
        payload_size = config.payload_size,
        "Starting ICMP ping test"
    );

    // Create separate clients for IPv4 and IPv6
    let client_v4 = Client::new(&Config::default())
        .context("Failed to create ICMPv4 client. On Linux/macOS, this requires elevated privileges (root or CAP_NET_RAW).")?;
    let client_v6 = Client::new(&Config::builder().kind(ICMP::V6).build())
        .context("Failed to create ICMPv6 client. On Linux/macOS, this requires elevated privileges (root or CAP_NET_RAW).")?;

    let client_v4 = Arc::new(client_v4);
    let client_v6 = Arc::new(client_v6);

    let (tx, mut rx) = mpsc::channel::<TargetResult>(config.targets.len());

    // Spawn a task for each target
    for (idx, target) in config.targets.iter().enumerate() {
        let tx = tx.clone();
        let config = config.clone();
        let target = *target;
        let client = if target.is_ipv4() {
            Arc::clone(&client_v4)
        } else {
            Arc::clone(&client_v6)
        };

        tokio::spawn(async move {
            let result = ping_target(idx, target, &config, &client).await;
            let _ = tx.send(result).await;
        });
    }

    drop(tx);

    // Collect results
    let mut all_results: Vec<TargetResult> = Vec::new();
    while let Some(result) = rx.recv().await {
        all_results.push(result);
    }

    // Build summary
    Ok(build_summary(&config, all_results))
}

/// Ping a single target.
async fn ping_target(
    idx: usize,
    target: IpAddr,
    config: &TestConfig,
    client: &Client,
) -> TargetResult {
    let mut pinger = client.pinger(target, PingIdentifier(idx as u16)).await;
    pinger.timeout(config.timeout);

    let payload = vec![0xAB; config.payload_size];
    let mut packets_sent = 0usize;
    let mut packets_received = 0usize;
    let mut rtts = StreamingStats::new();

    let start = Instant::now();
    let mut seq = 0u16;

    loop {
        // Check termination condition
        if let Some(count) = config.count
            && packets_sent >= count
        {
            break;
        }
        if let Some(duration) = config.duration
            && start.elapsed() >= duration
        {
            break;
        }

        packets_sent += 1;
        let ping_start = Instant::now();

        match pinger.ping(PingSequence(seq), &payload).await {
            Ok((_packet, rtt)) => {
                packets_received += 1;
                rtts.record(rtt);
                trace!(target = %target, seq, rtt_ms = rtt.as_secs_f64() * 1000.0, "Ping reply");
            }
            Err(e) => {
                debug!(target = %target, seq, error = %e, "Ping failed");
            }
        }

        seq = seq.wrapping_add(1);

        // Wait for next interval
        let elapsed = ping_start.elapsed();
        if elapsed < config.interval {
            tokio::time::sleep(config.interval - elapsed).await;
        }
    }

    let has_errors = packets_received < packets_sent;
    let loss_percent = if packets_sent > 0 {
        ((packets_sent - packets_received) as f64 / packets_sent as f64) * 100.0
    } else {
        0.0
    };
    crate::log_test_result!(
        has_errors,
        target = %target,
        sent = packets_sent,
        received = packets_received,
        loss_percent,
        "Target ping complete"
    );

    TargetResult {
        target,
        packets_sent,
        packets_received,
        rtts,
    }
}

/// Build the summary from all target results.
fn build_summary(config: &TestConfig, results: Vec<TargetResult>) -> PingTestSummary {
    let mut total_sent = 0usize;
    let mut total_received = 0usize;
    let mut all_rtts = StreamingStats::new();
    let mut per_target = Vec::new();

    for result in results {
        total_sent += result.packets_sent;
        total_received += result.packets_received;
        all_rtts.merge(&result.rtts);

        per_target.push(TargetSummary {
            target: result.target.to_string(),
            packets_sent: result.packets_sent,
            packets_received: result.packets_received,
            packet_loss_percent: if result.packets_sent > 0 {
                ((result.packets_sent - result.packets_received) as f64
                    / result.packets_sent as f64)
                    * 100.0
            } else {
                0.0
            },
            min_rtt_ms: result.rtts.min().map(|d| d.as_secs_f64() * 1000.0),
            max_rtt_ms: result.rtts.max().map(|d| d.as_secs_f64() * 1000.0),
            avg_rtt_ms: result.rtts.avg().map(|d| d.as_secs_f64() * 1000.0),
        });
    }

    let packet_loss_percent = if total_sent > 0 {
        ((total_sent - total_received) as f64 / total_sent as f64) * 100.0
    } else {
        0.0
    };

    PingTestSummary {
        test_type: "ping",
        targets: config.targets.iter().map(ToString::to_string).collect(),
        packets_sent: total_sent,
        packets_received: total_received,
        packet_loss_percent,
        min_rtt_ms: all_rtts.min().map(|d| d.as_secs_f64() * 1000.0),
        max_rtt_ms: all_rtts.max().map(|d| d.as_secs_f64() * 1000.0),
        avg_rtt_ms: all_rtts.avg().map(|d| d.as_secs_f64() * 1000.0),
        per_target,
    }
}
