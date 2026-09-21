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
    let mut portal = generator.portal();
    let mut reference = generator.reference_state(&portal);

    let mut tunnel = TunnelTest::init_test(&reference, &mut portal, flux_capacitor.clone());
    TunnelTest::check_invariants(&tunnel, &reference, &portal);

    for applied in 0..MAX_TRANSITIONS {
        if generator.is_empty() {
            break;
        }

        let transition = generator.transition(&reference, &portal);

        tracing::debug!("Applying transition {applied}: {transition:?}");

        ReferenceState::invalidate(&mut reference, &portal, &transition);
        TunnelTest::invalidate(&mut tunnel, &reference, &transition);

        portal.apply(&transition);
        reference = ReferenceState::apply(reference, &portal, &transition, flux_capacitor.now());
        tunnel = TunnelTest::apply(tunnel, &reference, &mut portal, transition);
        TunnelTest::check_invariants(&tunnel, &reference, &portal);
    }
});
