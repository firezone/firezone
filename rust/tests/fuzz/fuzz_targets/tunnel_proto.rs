//! Exercises the connlib tunnel state machine with coverage-guided fuzzing.

use std::time::Instant;

use chrono::{DateTime, Utc};
use fuzz::tunnel_proto::{
    FluxCapacitor, Generator, TunnelTest, check_invariants, init_fuzz_subscriber,
};

const MAX_TRANSITIONS: usize = 20;

fn main() -> anyhow::Result<()> {
    fuzz::run(test)?;

    Ok(())
}

fn test(data: &[u8]) {
    let _guard = init_fuzz_subscriber();

    let now = Instant::now();
    let utc_start = DateTime::<Utc>::from_timestamp(0, 0).expect("0 is a valid UNIX timestamp");
    let flux_capacitor = FluxCapacitor::new(now, utc_start);
    let mut generator = Generator::new(data);
    let mut portal = generator.portal();
    let mut reference = generator.reference_state(&portal);

    let mut tunnel = TunnelTest::init_test(&reference, &mut portal, flux_capacitor.clone());
    check_invariants(&reference, &tunnel, &portal);

    for applied in 0..MAX_TRANSITIONS {
        if generator.is_empty() {
            break;
        }

        let transition = generator.transition(&reference, &portal);

        tracing::debug!("Applying transition {applied}: {transition:?}");

        reference.invalidate(&transition, &portal);
        tunnel.invalidate(&transition, &reference);

        portal.apply(&transition);
        reference = reference.apply(&transition, &portal, flux_capacitor.now());
        tunnel = tunnel.apply(transition, &reference, &mut portal);
        check_invariants(&reference, &tunnel, &portal);
    }
}
