use crate::tests::{flux_capacitor::FluxCapacitor, sut::TunnelTest};
use assertions::PanicOnErrorEvents;
use chrono::Utc;
use core::fmt;
use proptest::{
    prelude::*,
    sample::SizeRange,
    strategy::{Strategy, ValueTree as _},
    test_runner::{Config, RngAlgorithm, TestError, TestRng, TestRunner},
};
use proptest_state_machine::Sequential;
use reference::ReferenceState;
use std::{
    sync::atomic::{self, AtomicU32},
    time::Instant,
};
use tracing_subscriber::{
    EnvFilter, Layer, layer::SubscriberExt as _, util::SubscriberInitExt as _,
};

mod assertions;
mod buffered_transmits;
mod composite_strategy;
mod dns_records;
mod dns_server_resource;
mod flux_capacitor;
mod icmp_error_hosts;
mod reference;
mod sim_client;
mod sim_gateway;
mod sim_net;
mod sim_relay;
mod strategies;
mod stub_portal;
mod sut;
mod tcp;
mod transition;

type QueryId = u16;

#[test]
fn tunnel_test() {
    let config = Config {
        source_file: Some(file!()),
        ..Default::default()
    };

    let test_index = AtomicU32::new(0);

    let _ = std::fs::remove_dir_all("testcases");
    let _ = std::fs::create_dir_all("testcases");

    let now = Instant::now();
    let utc_now = Utc::now();
    let flux_capacitor = FluxCapacitor::new(now, utc_now);

    let test_runner = &mut TestRunner::new(config);
    let strategy = Sequential::new(
        SizeRange::new(5..=15),
        move || ReferenceState::initial_state(now),
        ReferenceState::is_valid_transition,
        move |state| ReferenceState::transitions(state, now),
        {
            let flux_capacitor = flux_capacitor.clone();

            move |state, transition| ReferenceState::apply(state, transition, flux_capacitor.now())
        },
    );

    let result = test_runner.run(
        &strategy,
        |(mut ref_state, transitions, mut seen_counter)| {
            let test_index = test_index.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

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

            let mut sut = TunnelTest::init_test(&ref_state, flux_capacitor.clone());

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
                ref_state = ReferenceState::apply(ref_state, transition, flux_capacitor.now());
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

#[test_strategy::proptest]
fn transitions_and_state_are_deterministic(
    #[strategy(any::<u64>())] seed: u64,
    #[strategy(5..=15)] num_transitions: i32,
) {
    println!("Checking seed {seed} and {num_transitions} transitions");

    let now = Instant::now();

    let mut state1 = sample_from_strategy(seed, ReferenceState::initial_state(now));
    let mut state2 = sample_from_strategy(seed, ReferenceState::initial_state(now));

    assert_eq!(format!("{state1:?}"), format!("{state2:?}"));

    for _ in 0..num_transitions {
        let transition1 = sample_from_strategy(seed, ReferenceState::transitions(&state1, now));
        let transition2 = sample_from_strategy(seed, ReferenceState::transitions(&state2, now));

        assert_eq!(format!("{transition1:?}"), format!("{transition2:?}"));

        if !ReferenceState::is_valid_transition(&state1, &transition1)
            || !ReferenceState::is_valid_transition(&state2, &transition2)
        {
            continue;
        }

        state1 = ReferenceState::apply(state1, &transition1, now);
        state2 = ReferenceState::apply(state2, &transition2, now);

        assert_eq!(format!("{state1:?}"), format!("{state2:?}"));
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
        "debug,tunnel=trace,tunnel::tests=debug,tunnel_test_coverage=trace,ip_packet=trace"
            .to_owned();
    let env_filter = std::env::var("RUST_LOG").unwrap_or_default();

    EnvFilter::new([default_filter, env_filter].join(","))
}
