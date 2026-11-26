//! Drives the deterministic simulations from `tests/simulation` with ephyra.
//!
//! Each simulation checks its own invariants and panics when one is violated. The inputs
//! start from the AFL++ corpora of the fuzz harness and ephyra mutates them from there.

#![allow(clippy::unwrap_used)]

use std::{path::Path, sync::LazyLock, time::Instant};

use ephyra::loops::{self, SeedPool as _, Validity};
use ephyra::prelude::*;
use ephyra::{Gen, Run, gens};

static START: LazyLock<Instant> = LazyLock::new(Instant::now);

fn bytes() -> impl Gen<Value = Vec<u8>> + Clone {
    gens::vec(gens::int(0u8..=255)).len(0..=2048)
}

fn corpus(target: &str) -> Vec<Vec<u8>> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../fuzz/corpus")
        .join(target);
    let mut entries = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect::<Vec<_>>();
    entries.sort();

    entries
        .into_iter()
        .map(|p| std::fs::read(p).unwrap())
        .collect()
}

fn fuzz(name: &str, target: &str, simulate: fn(&[u8], Instant)) {
    let config = Config::default().tests(2_000).name(name);
    let mut run = Run::new(&config, bytes(), move |data: Vec<u8>| {
        seeded_rng::reset(0);
        simulate(&data, *START);
    });

    if !run.remembered() {
        let mut pool = loops::Fifo::with_energy(50);
        for input in corpus(target) {
            pool.invest(
                input,
                Validity {
                    valid: true,
                    score: 1.0,
                },
            );
        }
        let fuel = std::env::var("EPHYRA_FUEL").map_or(config.tests, |f| f.parse().unwrap());
        loops::fuzz(&mut run, &mut pool, fuel);
    }

    run.finish().assert_passed();
}

#[test]
fn tunnel_simulation_upholds_invariants() {
    fuzz(
        "tunnel_simulation_upholds_invariants",
        "tunnel",
        simulation::run_tunnel,
    );
}

#[test]
fn relay_simulation_upholds_invariants() {
    fuzz(
        "relay_simulation_upholds_invariants",
        "relay",
        simulation::run_relay,
    );
}
