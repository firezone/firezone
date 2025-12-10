#![expect(
    clippy::print_stdout,
    reason = "CLI tool outputs JSON metrics to stdout"
)]
#![cfg_attr(
    windows,
    expect(clippy::print_stderr, reason = "CLI tool outputs warnings to stderr")
)]

//! Load testing CLI for Firezone VPN.
//!
//! This tool uses Goose to perform load testing through the VPN tunnel.
//! It assumes the Firezone client is already connected.
//!
//! # Usage
//!
//! Run `firezone-loadtest -h` for all options
//! You can also see Goose docs: <https://book.goose.rs>
//!
//! Key flags:
//!
//! - `-H, --host HOST` - Target URL (default: <https://firezone.dev>)
//! - `-u, --users N` - Concurrent users (default: 10)
//! - `-t, --run-time TIME` - Duration like `30s`, `5m`, `1h` (default: 30s)
//! - `--report-file NAME` - Generate report (.html, .json, .md)
//! - `--no-print-metrics` - Suppress human-readable metrics output
//! - `-q` - Quiet mode (use `-qq` or `-qqq` for less output)
//!
//! # For Azure log ingestion (clean JSON output)
//! ```bash
//! firezone-loadtest -qq --no-print-metrics 2>/dev/null | tail -1
//! ```
//!
//! # Windows Event Log
//!
//! On Windows, events are logged to the Application Event Log under source
//! "Firezone-Loadtest". Register the source (as admin) with:
//! ```powershell
//! New-EventLog -LogName Application -Source "Firezone-Loadtest"
//! ```

use goose::config::GooseDefault;
use goose::metrics::GooseMetrics;
use goose::prelude::*;
use serde::Serialize;
use tracing_subscriber::util::SubscriberInitExt as _;

#[cfg(windows)]
const EVENT_LOG_SOURCE: &str = "Firezone-Loadtest";
const DEFAULT_HOST: &str = "https://example.com";
const DEFAULT_USERS: usize = 10;
const DEFAULT_RUN_TIME: usize = 30;

/// Simplified metrics summary for Azure log ingestion.
///
/// Uses values directly from Goose without additional calculation.
#[derive(Serialize)]
struct LoadTestSummary {
    target_host: String,
    duration_secs: usize,
    total_requests: usize,
    successful_requests: usize,
    failed_requests: usize,
    min_response_time_ms: usize,
    max_response_time_ms: usize,
    avg_response_time_ms: usize,
}

impl LoadTestSummary {
    #[expect(
        clippy::disallowed_methods,
        reason = "Iterating to find our single endpoint"
    )]
    fn from_metrics(metrics: &GooseMetrics) -> Self {
        // We only have one endpoint ("GET /"), so grab its data directly
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
async fn main() -> Result<(), GooseError> {
    init_logging();

    tracing::info!(
        host = DEFAULT_HOST,
        users = DEFAULT_USERS,
        run_time_secs = DEFAULT_RUN_TIME,
        "load test started"
    );

    let metrics = GooseAttack::initialize()?
        .set_default(GooseDefault::Host, DEFAULT_HOST)?
        .set_default(GooseDefault::Users, DEFAULT_USERS)?
        .set_default(GooseDefault::RunTime, DEFAULT_RUN_TIME)?
        .set_default(GooseDefault::NoResetMetrics, true)?
        .register_scenario(
            scenario!("LoadTest").register_transaction(transaction!(load_test_request)),
        )
        .execute()
        .await?;

    // Output simplified metrics as JSON for Azure log ingestion
    let summary = LoadTestSummary::from_metrics(&metrics);

    tracing::info!(
        target_host = %summary.target_host,
        duration_secs = summary.duration_secs,
        total_requests = summary.total_requests,
        successful_requests = summary.successful_requests,
        failed_requests = summary.failed_requests,
        min_response_time_ms = summary.min_response_time_ms,
        max_response_time_ms = summary.max_response_time_ms,
        avg_response_time_ms = summary.avg_response_time_ms,
        "load test completed"
    );

    println!(
        "{}",
        serde_json::to_string(&summary).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Initializes logging with optional Windows Event Log support.
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
        tracing_subscriber::registry().init();
    }
}

/// Performs an HTTP GET request and validates the response.
async fn load_test_request(user: &mut GooseUser) -> TransactionResult {
    let mut goose = user.get("/").await?;

    // Validate response status is 2xx
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
