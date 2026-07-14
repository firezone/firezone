//! Shared fuzz harness for connlib's tunnel state machine.
//!
//! Extracted from the `tunnel` crate (behind its `test-util` feature) so the
//! reference model and system-under-test wrapper can drive the fuzzer. Because
//! the harness is consumed selectively by the fuzz entry point, not every item
//! is reachable in a plain library build; and, like the test code it grew out
//! of, it leans on `unwrap` and stdout.
#![allow(dead_code)]
#![allow(clippy::unwrap_used, clippy::unwrap_in_result)]
#![allow(clippy::print_stdout, clippy::print_stderr)]

use assertions::PanicOnErrorEvents;
use tracing_subscriber::{
    EnvFilter, Layer, layer::SubscriberExt as _, util::SubscriberInitExt as _,
};

mod arb;
mod assertions;
mod buffered_transmits;
mod dns_records;
mod dns_server_resource;
mod echo;
mod flux_capacitor;
mod icmp_error_hosts;
mod ref_client;
mod ref_gateway;
mod reference;
mod sim_client;
mod sim_gateway;
mod sim_net;
mod sim_relay;
mod stub_portal;
mod sut;
mod tcp;
mod transition;

pub use arb::run_fuzz_case_structured;

type QueryId = u16;

/// Scope an error-detecting subscriber to the current fuzz case.
///
/// Used by the fuzz entry point ([`run_fuzz_case_structured`]). Mass fuzzing
/// installs only [`PanicOnErrorEvents`] and writes no logs; setting `RUST_LOG`
/// (e.g. when reproducing a saved crash) additionally writes a trace to stderr.
fn init_fuzz_subscriber() -> tracing::subscriber::DefaultGuard {
    let registry = tracing_subscriber::registry().with(PanicOnErrorEvents::new(0));

    if std::env::var_os("RUST_LOG").is_some() {
        registry
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(std::io::stderr)
                    .with_ansi(false)
                    .with_filter(log_file_filter()),
            )
            .set_default()
    } else {
        registry.set_default()
    }
}

fn log_file_filter() -> EnvFilter {
    let default_filter =
        "debug,tunnel=trace,tunnel_tests=debug,ip_packet=trace,path_agent=trace".to_owned();
    let env_filter = std::env::var("RUST_LOG").unwrap_or_default();

    EnvFilter::new([default_filter, env_filter].join(","))
}
