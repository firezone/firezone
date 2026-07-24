//! Fuzz harness for connlib's tunnel state machine.
//!
//! The reference model and system-under-test wrapper live with their only
//! consumer while remaining a library so their focused unit tests stay
//! runnable. Like the test code they grew out of, they lean on `unwrap` and
//! stdout.
#![allow(dead_code)]
#![allow(clippy::unwrap_used, clippy::unwrap_in_result)]
#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::time::Instant;

use assertions::PanicOnErrorEvents;
use chrono::{DateTime, Utc};
use tracing_subscriber::{
    EnvFilter, Layer, layer::SubscriberExt as _, util::SubscriberInitExt as _,
};

use crate::flux_capacitor::FluxCapacitor;
use crate::reference::ReferenceState;
use crate::sut::TunnelTest;

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
mod resource;
mod sim_client;
mod sim_gateway;
mod sim_net;
mod sim_relay;
mod stub_portal;
mod sut;
mod tcp;
mod transition;

type QueryId = u16;

/// Upper bound on transitions applied per fuzz case.
const MAX_TRANSITIONS: usize = 20;

/// Drive one deterministic tunnel scenario from `data`.
///
/// Input is read left-to-right through one
/// [`arbitrary::Unstructured`]. Exhaustion degrades each choice to its minimum
/// or default, so truncated inputs remain valid scenarios and simply apply
/// fewer transitions.
pub fn run(data: &[u8]) {
    let _guard = init_fuzz_subscriber();

    let now = Instant::now();
    let utc_start = DateTime::<Utc>::from_timestamp(0, 0).expect("0 is a valid UNIX timestamp");
    let flux_capacitor = FluxCapacitor::new(now, utc_start);
    let mut generator = arb::Generator::new(data);
    let mut ref_state = generator.initial_state(now);

    let mut sut = TunnelTest::init_test(&ref_state, flux_capacitor.clone());
    TunnelTest::check_invariants(&sut, &ref_state);

    for applied in 0..MAX_TRANSITIONS {
        if generator.is_empty() {
            break;
        }

        let Some(transition) = generator.transition(&ref_state, now) else {
            break;
        };

        tracing::debug!("Applying transition {applied}: {transition:?}");

        if transition.should_clear_packets() {
            ReferenceState::clear_packets(&mut ref_state);
            TunnelTest::clear_packets(&mut sut);
        }

        ref_state = ReferenceState::apply(ref_state, &transition, flux_capacitor.now());
        sut = TunnelTest::apply(sut, &ref_state, transition.clone());
        TunnelTest::check_invariants(&sut, &ref_state);
    }
}

/// Scope an error-detecting subscriber to the current fuzz case.
///
/// Mass fuzzing installs only [`PanicOnErrorEvents`] and writes no logs; setting
/// `RUST_LOG` (e.g. when reproducing a saved crash) additionally writes a trace
/// to stderr.
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
        "debug,tunnel_proto=trace,fuzz=debug,ip_packet=trace,path_agent=trace".to_owned();
    let env_filter = std::env::var("RUST_LOG").unwrap_or_default();

    EnvFilter::new([default_filter, env_filter].join(","))
}

#[cfg(test)]
mod tests {
    #[test]
    fn structured_fuzz_case_smoke() {
        super::run(&[]);
        super::run(&[0; 64]);
        super::run(&[0xAB; 256]);

        let ramp = (0u8..=255).cycle().take(8192).collect::<Vec<_>>();
        super::run(&ramp);
    }
}
