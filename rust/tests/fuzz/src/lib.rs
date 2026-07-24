//! Fuzz harness for connlib's tunnel state machine.
//!
//! The reference model and system-under-test wrapper live with their only
//! consumer while remaining a library so their focused unit tests stay
//! runnable. Like the test code they grew out of, they lean on `unwrap` and
//! stdout.
#![allow(dead_code)]
#![allow(clippy::unwrap_used, clippy::unwrap_in_result)]
#![allow(clippy::print_stdout, clippy::print_stderr)]

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

/// The tunnel-proto target's reference-model harness.
pub mod tunnel_proto {
    use tracing_subscriber::{
        EnvFilter, Layer, layer::SubscriberExt as _, util::SubscriberInitExt as _,
    };

    use super::assertions::PanicOnErrorEvents;

    pub use super::arb::Generator;
    pub use super::flux_capacitor::FluxCapacitor;
    pub use super::reference::ReferenceState;
    pub use super::sut::TunnelTest;
    pub use super::transition::Transition;

    /// Scope an error-detecting subscriber to the current fuzz case.
    ///
    /// Mass fuzzing writes no logs; setting `RUST_LOG` additionally writes a
    /// trace to stderr when reproducing a saved crash.
    pub fn init_fuzz_subscriber() -> tracing::subscriber::DefaultGuard {
        const DEFAULT_FILTER: &str =
            "debug,tunnel_proto=trace,fuzz=debug,ip_packet=trace,path_agent=trace";

        let log_layer = std::env::var("RUST_LOG").ok().map(|filter| {
            tracing_subscriber::fmt::layer()
                .with_writer(std::io::stderr)
                .with_ansi(false)
                .with_filter(EnvFilter::new(format!("{DEFAULT_FILTER},{filter}")))
        });

        tracing_subscriber::registry()
            .with(PanicOnErrorEvents::new(0))
            .with(log_layer)
            .set_default()
    }
}
