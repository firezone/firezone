//! libFuzzer entry point that drives the tunnel state machine from raw bytes.
//!
//! The proptest suite (the `tunnel_test` function) samples scenarios from a
//! proptest strategy using a pseudo-random generator. The fuzz target reuses
//! the very same building blocks — [`ReferenceState::initial_state`],
//! [`ReferenceState::transitions`], [`ReferenceState::is_valid_transition`] and
//! [`ReferenceState::apply`] — but derives the generator's seed from libFuzzer's
//! input, so its coverage-guided corpus evolution steers which scenarios (and
//! thus which connlib code paths) get exercised.
//!
//! ## Why seed a PRNG instead of `RngAlgorithm::PassThrough`?
//!
//! The "obvious" structured approach feeds the fuzzer's bytes straight into
//! proptest via [`RngAlgorithm::PassThrough`], giving a byte → decision mapping
//! that preserves mutation locality. In practice the harness strategies (unique
//! IP / key assignment, stub-portal layout, …) resample until their constraints
//! are met, and `PassThrough` yields zeros once exhausted — so any low-entropy
//! input spins forever. Seeding a ChaCha PRNG from the input sidesteps that: the
//! strategies always see well-distributed entropy (exactly as under proptest),
//! so generation always terminates, while libFuzzer still keeps inputs that
//! reach new coverage. The trade-off is weaker mutation locality; see the
//! coverage-instrumentation design notes for a path back to structured input.

use std::time::Instant;

use chrono::{DateTime, Utc};
use proptest::{
    strategy::{Strategy, ValueTree as _},
    test_runner::{Config, RngAlgorithm, TestRng, TestRunner},
};
use tracing_subscriber::{layer::SubscriberExt as _, util::SubscriberInitExt as _};

use crate::assertions::PanicOnErrorEvents;
use crate::flux_capacitor::FluxCapacitor;
use crate::reference::ReferenceState;
use crate::sut::TunnelTest;

/// Upper bound on transitions applied per case (the proptest suite uses 5..=15).
const MAX_TRANSITIONS: usize = 20;

/// Hard cap on sampling attempts, so a case always terminates even if many
/// sampled transitions fail their pre-conditions in the current state.
const MAX_ATTEMPTS: usize = 400;

/// Interpret `data` as the seed for a single state-machine scenario and replay
/// it against the system-under-test, asserting connlib's invariants.
///
/// This is the function wired up to the `tunnel` libFuzzer target.
pub fn run_fuzz_case(data: &[u8]) {
    // Treat any `ERROR` log as a failure, exactly like the proptest harness, but
    // without an output layer so the fuzzer stays quiet and fast. The guard
    // scopes the subscriber to this case.
    let _guard = tracing_subscriber::registry()
        .with(PanicOnErrorEvents::new(0))
        .set_default();

    let now = Instant::now();
    // A fixed UTC start keeps a given input fully reproducible (libFuzzer
    // replays crashing inputs). connlib's clock-derived behaviour is
    // deterministic given the injected clock, so the absolute start is irrelevant.
    let utc_start = DateTime::<Utc>::from_timestamp(0, 0).expect("0 is a valid UNIX timestamp");
    let flux_capacitor = FluxCapacitor::new(now, utc_start);

    let mut runner = TestRunner::new_with_rng(Config::default(), seed_rng(data));

    let Ok(mut ref_state) = ReferenceState::initial_state(now)
        .new_tree(&mut runner)
        .map(|tree| tree.current())
    else {
        return;
    };

    let mut sut = TunnelTest::init_test(&ref_state, flux_capacitor.clone());
    TunnelTest::check_invariants(&sut, &ref_state);

    let mut applied = 0;
    for _ in 0..MAX_ATTEMPTS {
        if applied >= MAX_TRANSITIONS {
            break;
        }

        let Ok(transition) = ReferenceState::transitions(&ref_state, now)
            .new_tree(&mut runner)
            .map(|tree| tree.current())
        else {
            break;
        };

        if !ReferenceState::is_valid_transition(&ref_state, &transition) {
            continue;
        }

        if transition.should_clear_packets() {
            ReferenceState::clear_packets(&mut ref_state);
            TunnelTest::clear_packets(&mut sut);
        }

        ref_state = ReferenceState::apply(ref_state, &transition, flux_capacitor.now());
        sut = TunnelTest::apply(sut, &ref_state, transition.clone());
        TunnelTest::check_invariants(&sut, &ref_state);

        applied += 1;
    }
}

/// Derive a deterministic proptest RNG from the fuzzer's input.
///
/// ChaCha needs a 32-byte seed; we fold the whole input into it so that inputs
/// of any length contribute, then let ChaCha expand it into a high-quality
/// stream regardless of how little entropy the input carried.
fn seed_rng(data: &[u8]) -> TestRng {
    let mut seed = [0u8; 32];
    for (i, byte) in data.iter().enumerate() {
        seed[i % 32] ^= byte;
    }
    TestRng::from_seed(RngAlgorithm::ChaCha, &seed)
}

#[cfg(test)]
mod tests {
    use super::*;

    // A handful of byte patterns must each drive a scenario (or bail cleanly)
    // without panicking or hanging. This keeps the fuzz entry point compiling
    // and runnable even in environments without `cargo-fuzz`.
    #[test]
    fn run_fuzz_case_smoke() {
        run_fuzz_case(&[]);
        run_fuzz_case(&[0u8; 64]);
        run_fuzz_case(&[0xAB; 256]);

        let ramp: Vec<u8> = (0u8..=255).cycle().take(4096).collect();
        run_fuzz_case(&ramp);
    }
}
