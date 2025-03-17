use crate::tests::{flux_capacitor::FluxCapacitor, sut::TunnelTest};
use assertions::PanicOnErrorEvents;
use core::fmt;
use proptest::{
    sample::SizeRange,
    strategy::{Strategy, ValueTree as _},
    test_runner::{Config, RngAlgorithm, TestError, TestRng, TestRunner},
};
use proptest_state_machine::Sequential;
use reference::ReferenceState;
use std::sync::atomic::{self, AtomicU32};
use tracing_subscriber::{
    EnvFilter, Layer, layer::SubscriberExt as _, util::SubscriberInitExt as _,
};

mod assertions;
mod buffered_transmits;
mod composite_strategy;
mod dns_records;
mod dns_server_resource;
mod flux_capacitor;
mod reference;
mod sim_client;
mod sim_gateway;
mod sim_net;
mod sim_relay;
mod strategies;
mod stub_portal;
mod sut;
mod transition;
mod unreachable_hosts;

type QueryId = u16;

#[test]
#[expect(clippy::print_stdout, clippy::print_stderr)]
fn tunnel_test() {
    let config = Config {
        source_file: Some(file!()),
        ..Default::default()
    };

    let test_index = AtomicU32::new(0);

    let _ = std::fs::remove_dir_all("testcases");
    let _ = std::fs::create_dir_all("testcases");

    let test_runner = &mut TestRunner::new(config);
    let strategy = Sequential::new(
        SizeRange::new(5..=15),
        ReferenceState::initial_state,
        ReferenceState::is_valid_transition,
        ReferenceState::transitions,
        ReferenceState::apply,
    );

    let result = test_runner.run(
        &strategy,
        |(mut ref_state, transitions, mut seen_counter)| {
            let test_index = test_index.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let flux_capacitor = FluxCapacitor::default();

            let _guard = init_logging(flux_capacitor.clone(), test_index);

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

            let mut sut = TunnelTest::init_test(&ref_state, flux_capacitor);

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

            Ok(())
        },
    );

    println!("TestRunner stats: \n\n{test_runner}");

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

#[test]
fn reference_state_is_deterministic() {
    for n in 0..1000 {
        let state1 = sample_from_strategy(n, ReferenceState::initial_state());
        let state2 = sample_from_strategy(n, ReferenceState::initial_state());

        assert_eq!(format!("{state1:?}"), format!("{state2:?}"));
    }
}

#[test]
fn transitions_are_deterministic() {
    for n in 0..1000 {
        let state = sample_from_strategy(n, ReferenceState::initial_state());
        let transitions1 = sample_from_strategy(n, ReferenceState::transitions(&state));
        let transitions2 = sample_from_strategy(n, ReferenceState::transitions(&state));

        assert_eq!(format!("{transitions1:?}"), format!("{transitions2:?}"));
    }
}

fn sample_from_strategy<S, T>(seed: u64, strategy: S) -> T
where
    S: Strategy<Value = T> + fmt::Debug,
    T: fmt::Debug,
{
    strategy
        .new_tree(&mut TestRunner::new_with_rng(
            Config::default(),
            TestRng::from_seed(
                RngAlgorithm::default(),
                seed.to_be_bytes().repeat(4).as_slice(),
            ),
        ))
        .unwrap()
        .current()
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
fn init_logging(
    flux_capacitor: FluxCapacitor,
    test_index: u32,
) -> tracing::subscriber::DefaultGuard {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .with_test_writer()
                .with_timer(flux_capacitor.clone())
                .with_filter(EnvFilter::from_default_env()),
        )
        .with(
            tracing_subscriber::fmt::layer()
                .with_writer(std::fs::File::create(format!("testcases/{test_index}.log")).unwrap())
                .with_timer(flux_capacitor)
                .with_ansi(false)
                .with_filter(log_file_filter()),
        )
        .with(PanicOnErrorEvents::new(test_index))
        .set_default()
}

fn log_file_filter() -> EnvFilter {
    let default_filter =
        "debug,firezone_tunnel=trace,firezone_tunnel::tests=debug,tunnel_test_coverage=trace,ip_packet=trace".to_owned();
    let env_filter = std::env::var("RUST_LOG").unwrap_or_default();

    EnvFilter::new([default_filter, env_filter].join(","))
}
