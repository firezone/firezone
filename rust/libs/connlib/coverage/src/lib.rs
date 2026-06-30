//! Tiny semantic-coverage registry shared across connlib crates.
//!
//! `coverage::cov!("some.label")` records that a particular code path executed.
//! The `tunnel-tests` proptest harness asserts that every required label was hit
//! at least once. This replaces grepping rendered log output for magic
//! substrings: a marker lives at the code site it describes, so it moves with
//! refactors instead of silently breaking when a log message is reworded, and
//! it is far cheaper than formatting and scanning every event.
//!
//! Counting only happens with the `enabled` feature (turned on by the harness).
//! In production builds [`hit`] is an empty inline function, so the markers
//! compile away to nothing.

/// Record a hit for the semantic-coverage `label` (a string literal).
#[macro_export]
macro_rules! cov {
    ($label:literal) => {
        $crate::hit($label)
    };
}

#[cfg(feature = "enabled")]
mod registry {
    use std::collections::BTreeMap;
    use std::sync::Mutex;

    static HITS: Mutex<BTreeMap<&'static str, u64>> = Mutex::new(BTreeMap::new());

    /// Record a hit for `label`.
    pub fn hit(label: &'static str) {
        if let Ok(mut hits) = HITS.lock() {
            *hits.entry(label).or_insert(0) += 1;
        }
    }

    /// How many times `label` has been hit since the last [`reset`].
    pub fn count(label: &str) -> u64 {
        HITS.lock()
            .map(|hits| hits.get(label).copied().unwrap_or(0))
            .unwrap_or(0)
    }

    /// Clear all recorded hits.
    pub fn reset() {
        if let Ok(mut hits) = HITS.lock() {
            hits.clear();
        }
    }
}

#[cfg(feature = "enabled")]
pub use registry::{count, hit, reset};

/// No-op stand-in compiled when coverage is disabled (e.g. production builds).
#[cfg(not(feature = "enabled"))]
#[inline(always)]
pub fn hit(_label: &'static str) {}
