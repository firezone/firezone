#![no_main]

//! Exercises the connlib tunnel state machine with coverage-guided fuzzing.

use std::time::Instant;

use chrono::{DateTime, Utc};
use fuzz::tunnel_proto::{
    FluxCapacitor, Generator, ReferenceState, TunnelTest, init_fuzz_subscriber,
};
use libfuzzer_sys::fuzz_target;

const MAX_TRANSITIONS: usize = 20;

fuzz_target!(|data: &[u8]| {
    let _guard = init_fuzz_subscriber();

    let now = Instant::now();
    let utc_start = DateTime::<Utc>::from_timestamp(0, 0).expect("0 is a valid UNIX timestamp");
    let flux_capacitor = FluxCapacitor::new(now, utc_start);
    let mut generator = Generator::new(data);
    let mut reference = generator.initial_state();

    let mut tunnel = TunnelTest::init_test(&reference, flux_capacitor.clone());
    TunnelTest::check_invariants(&tunnel, &reference);
    ReferenceState::clear_expected_probes(&mut reference);
    TunnelTest::clear_probe_observations(&mut tunnel);

    for applied in 0..MAX_TRANSITIONS {
        if generator.is_empty() {
            break;
        }

        let Some(transition) = generator.transition(&reference) else {
            break;
        };

        tracing::debug!("Applying transition {applied}: {transition:?}");

        if transition.should_clear_packets() {
            ReferenceState::clear_packets(&mut reference);
            TunnelTest::clear_packets(&mut tunnel);
        }

        reference = ReferenceState::apply(reference, &transition, flux_capacitor.now_instant());
        tunnel = TunnelTest::apply(tunnel, &reference, transition);
        TunnelTest::check_invariants(&tunnel, &reference);
        ReferenceState::clear_expected_probes(&mut reference);
        TunnelTest::clear_probe_observations(&mut tunnel);
    }
});
