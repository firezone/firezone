use crate::tests::sut::TunnelTest;
use assertions::PanicOnErrorEvents;
use proptest::test_runner::{Config, TestError, TestRunner};
use proptest_state_machine::{ReferenceStateMachine, StateMachineTest};
use reference::ReferenceState;
use std::sync::atomic::{self, AtomicU32};
use tracing::level_filters::LevelFilter;
use tracing_subscriber::{
    layer::SubscriberExt as _, util::SubscriberInitExt as _, EnvFilter, Layer,
};

mod assertions;
mod buffered_transmits;
mod composite_strategy;
mod flux_capacitor;
mod reference;
mod sim_client;
mod sim_dns;
mod sim_gateway;
mod sim_net;
mod sim_relay;
mod strategies;
mod stub_portal;
mod sut;
mod transition;

type QueryId = u16;
type IcmpSeq = u16;
type IcmpIdentifier = u16;

#[test]
#[allow(clippy::print_stdout, clippy::print_stderr)]
fn tunnel_test() {
    let config = Config {
        source_file: Some(file!()),
        ..Default::default()
    };

    let test_index = AtomicU32::new(0);

    let _ = std::fs::remove_dir_all("testcases");
    let _ = std::fs::create_dir_all("testcases");

    let result = TestRunner::new(config).run(
        &ReferenceState::sequential_strategy(5..15),
        |(mut ref_state, transitions, mut seen_counter)| {
            let test_index = test_index.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let _guard = init_logging(&ref_state, test_index);

            std::fs::write(
                format!("testcases/{test_index}.state"),
                format!("{ref_state:#?}"),
            )
            .unwrap();
            std::fs::write(
                format!("testcases/{test_index}.transitions"),
                format!("{transitions:#?}"),
            )
            .unwrap();

            let num_transitions = transitions.len();

            println!("Running test case {test_index:04} with {num_transitions:02} transitions");

            let mut sut = TunnelTest::init_test(&ref_state);

            // Check the invariants on the initial state
            TunnelTest::check_invariants(&sut, &ref_state);

            for (ix, transition) in transitions.iter().enumerate() {
                // The counter is `Some` only before shrinking. When it's `Some` it
                // must be incremented before every transition that's being applied
                // to inform the strategy that the transition has been applied for
                // the first step of its shrinking process which removes any unseen
                // transitions.
                if let Some(seen_counter) = seen_counter.as_mut() {
                    seen_counter.fetch_add(1, atomic::Ordering::SeqCst);
                }

                tracing::info!(
                    "\n\nApplying transition {}/{num_transitions}: {transition:?}\n",
                    ix + 1,
                );

                // Apply the transition on the states
                ref_state = ReferenceState::apply(ref_state, transition);
                sut = TunnelTest::apply(sut, &ref_state, transition.clone());

                // Check the invariants after the transition is applied
                TunnelTest::check_invariants(&sut, &ref_state);
            }

            TunnelTest::teardown(sut);

            Ok(())
        },
    );

    let Err(e) = result else {
        return;
    };

    match e {
        TestError::Abort(msg) => panic!("Test aborted: {msg}"),
        TestError::Fail(msg, (ref_state, transitions, _)) => {
            eprintln!("{ref_state:#?}");
            eprintln!("{transitions:#?}");

            panic!("{msg}")
        }
    }
}

/// Initialise logging for [`TunnelTest`].
///
/// Log-level can be controlled with `RUST_LOG`.
/// By default, `debug` logs will be written to the `testcases/` directory for each test run.
/// This allows us to download logs from CI.
/// For stdout, only the default log filter applies.
///
/// Finally, we install [`PanicOnErrorEvents`] into the registry.
/// An `ERROR` log is treated as a fatal error and will fail the test.
fn init_logging(ref_state: &ReferenceState, test_index: u32) -> tracing::subscriber::DefaultGuard {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .with_test_writer()
                .with_timer(ref_state.flux_capacitor.clone())
                .with_filter(EnvFilter::from_default_env()),
        )
        .with(
            tracing_subscriber::fmt::layer()
                .with_writer(std::fs::File::create(format!("testcases/{test_index}.log")).unwrap())
                .with_timer(ref_state.flux_capacitor.clone())
                .with_ansi(false)
                .with_filter(
                    EnvFilter::builder()
                        .with_default_directive(LevelFilter::DEBUG.into())
                        .from_env()
                        .unwrap(),
                ),
        )
        .with(PanicOnErrorEvents::new(test_index))
        .set_default()
}
