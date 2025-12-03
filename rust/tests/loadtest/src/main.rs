#![expect(clippy::print_stdout, reason = "CLI tool outputs JSON metrics to stdout")]

//! HTTP load testing CLI for Firezone VPN.
//!
//! This tool uses Goose to perform load testing through the VPN tunnel.
//! It assumes the Firezone client is already connected.
//!
//! # Usage
//!
//! Run `firezone-loadtest -h` for all options
//! You can also see Goose docs: https://book.goose.rs
//!
//!  Key flags:
//!
//! - `-H, --host HOST` - Target URL (default: <https://firezone.dev>)
//! - `-u, --users N` - Concurrent users (default: 10)
//! - `-t, --run-time TIME` - Duration like `30s`, `5m`, `1h` (default: 30s)
//! - `--report-file NAME` - Generate report (.html, .json, .md)
//! - `--no-print-metrics` - Suppress human-readable metrics output
//! - `-q` - Quiet mode (use `-qq` or `-qqq` for less output)
//!
//! # For Azure log ingestion (clean JSON output)
//! firezone-loadtest -qq --no-print-metrics 2>/dev/null | tail -1
//! ```

use goose::config::GooseDefault;
use goose::metrics::GooseMetrics;
use goose::prelude::*;
use serde::Serialize;

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
    #[expect(clippy::disallowed_methods, reason = "Iterating to find our single endpoint")]
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
    let metrics = GooseAttack::initialize()?
        .set_default(GooseDefault::Host, "https://example.com")?
        .set_default(GooseDefault::Users, 10_usize)?
        .set_default(GooseDefault::RunTime, 30_usize)?
        .set_default(GooseDefault::NoResetMetrics, true)?
        .register_scenario(
            scenario!("LoadTest").register_transaction(transaction!(load_test_request)),
        )
        .execute()
        .await?;

    // Output simplified metrics as JSON for Azure log ingestion
    let summary = LoadTestSummary::from_metrics(&metrics);
    println!(
        "{}",
        serde_json::to_string(&summary).expect("Failed to serialize metrics")
    );

    Ok(())
}

/// Performs an HTTP GET request and validates the response.
async fn load_test_request(user: &mut GooseUser) -> TransactionResult {
    let mut goose = user.get("/").await?;

    // Validate response status is 2xx
    if let Ok(response) = goose.response
        && !response.status().is_success()
    {
        let status = response.status();
        return user.set_failure(&format!("{status}"), &mut goose.request, None, None);
    }

    Ok(())
}
