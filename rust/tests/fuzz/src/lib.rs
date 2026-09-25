//! Provides the fuzz harness for connlib's tunnel state machine.
#![allow(clippy::unwrap_used, clippy::unwrap_in_result)]
#![allow(clippy::print_stdout, clippy::print_stderr)]

mod arb;
mod assertions;
mod buffered_transmits;
mod dns_records;
mod dns_server_resource;
mod echo;
mod flux_capacitor;
mod fuzzer_feedback;
mod icmp_error_hosts;
mod os;
mod probe;
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

/// Records a combination of boolean state predicates as feedback for the fuzzer.
///
/// Each call site records its combinations independently. Arguments are evaluated
/// once, in order, with the first argument in the lowest bit. At most 16 booleans
/// fit in AFL++'s IJON set bitmap. Annotations must run on a single thread.
/// Replay evaluates the predicates without recording feedback.
#[macro_export]
macro_rules! record_fuzzer_feedback {
    ($($flag:expr),+ $(,)?) => {{
        const {
            assert!(
                [$(stringify!($flag)),+].len() <= 16,
                "fuzzer feedback supports at most 16 booleans",
            );
        }
        let flags: &[bool] = &[$($flag),+];
        let value = flags.iter().enumerate().fold(0, |value, (bit, flag)| {
            value | (u16::from(*flag) << bit)
        });
        $crate::record_fuzzer_feedback_value!(value);
    }};
}

/// Records a numeric state category as feedback for the fuzzer.
///
/// Each call site records its values independently. The argument is a `u16`
/// evaluated once, including during replay. Prefer small enums or bounded buckets
/// over raw identifiers and counters. Annotations must run on a single thread.
#[macro_export]
macro_rules! record_fuzzer_feedback_value {
    ($value:expr $(,)?) => {{
        let value: u16 = $value;
        ::core::cfg_select! {
            fuzzing => { ::afl::ijon_set!(u32::from(value)); }
            _ => { let _ = value; }
        }
    }};
}

type QueryId = u16;

/// Provides the tunnel-proto target's reference-model harness.
pub mod tunnel_proto {
    use tracing_subscriber::{
        EnvFilter, Layer, layer::SubscriberExt as _, util::SubscriberInitExt as _,
    };

    use super::assertions::PanicOnErrorEvents;

    pub use super::arb::Generator;
    pub use super::assertions::check_invariants;
    pub use super::flux_capacitor::FluxCapacitor;
    pub use super::fuzzer_feedback::record as record_fuzzer_feedback;
    pub use super::reference::ReferenceState;
    pub use super::stub_portal::StubPortal;
    pub use super::sut::TunnelTest;

    /// Initializes an error-detecting subscriber for the current fuzz case.
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
            .with(PanicOnErrorEvents::new())
            .with(log_layer)
            .set_default()
    }
}
