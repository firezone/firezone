//! A behaviour-preserving replacement for the unmaintained `backoff` crate, backed by [`backon`].
//!
//! We only ever used the upstream `backoff` crate as a stateful exponential-delay iterator: build
//! a strategy, then call [`ExponentialBackoff::next_backoff`] to get each delay. This crate keeps
//! that exact surface (including the public `max_elapsed_time` field, which callers surface in
//! their reconnect events) while delegating the interval maths to [`backon::ExponentialBuilder`].
//!
//! Two intentional differences from the original crate:
//! - The retry budget (`max_elapsed_time`) is mapped onto [`backon`]'s `with_total_delay`, which
//!   bounds the *cumulative* delay rather than wall-clock time. For large reconnect budgets this
//!   is indistinguishable in practice.
//! - `randomization_factor` only toggles [`backon`]'s jitter on/off; the exact jitter distribution
//!   differs. Strategies that disable jitter (`randomization_factor == 0.0`) remain fully
//!   deterministic.

use backon::{BackoffBuilder, ExponentialBuilder};
use std::time::Duration;

/// Builder for an [`ExponentialBackoff`], mirroring the upstream `backoff` crate's
/// `ExponentialBackoffBuilder`.
///
/// The logical configuration is stored verbatim and only translated to [`backon`] in
/// [`ExponentialBackoffBuilder::build`]. This lets us reproduce the *original* crate's defaults
/// (rather than `backon`'s) for any field a caller leaves unset.
#[derive(Debug, Clone)]
pub struct ExponentialBackoffBuilder {
    initial_interval: Duration,
    max_interval: Duration,
    multiplier: f64,
    randomization_factor: f64,
    max_elapsed_time: Option<Duration>,
}

impl Default for ExponentialBackoffBuilder {
    fn default() -> Self {
        // These mirror the `backoff` crate's defaults so that callers who only override a subset
        // of the configuration keep their previous behaviour.
        Self {
            initial_interval: Duration::from_millis(500),
            max_interval: Duration::from_secs(60),
            multiplier: 1.5,
            randomization_factor: 0.5,
            max_elapsed_time: Some(Duration::from_secs(15 * 60)),
        }
    }
}

impl ExponentialBackoffBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_initial_interval(mut self, initial_interval: Duration) -> Self {
        self.initial_interval = initial_interval;
        self
    }

    pub fn with_max_interval(mut self, max_interval: Duration) -> Self {
        self.max_interval = max_interval;
        self
    }

    pub fn with_multiplier(mut self, multiplier: f64) -> Self {
        self.multiplier = multiplier;
        self
    }

    pub fn with_randomization_factor(mut self, randomization_factor: f64) -> Self {
        self.randomization_factor = randomization_factor;
        self
    }

    pub fn with_max_elapsed_time(mut self, max_elapsed_time: Option<Duration>) -> Self {
        self.max_elapsed_time = max_elapsed_time;
        self
    }

    pub fn build(self) -> ExponentialBackoff {
        let mut inner = ExponentialBuilder::default()
            .with_min_delay(self.initial_interval)
            .with_max_delay(self.max_interval)
            .with_factor(self.multiplier as f32)
            .with_total_delay(self.max_elapsed_time)
            // `backon` defaults to retrying at most 3 times; we bound retries by the time budget.
            .without_max_times();

        if self.randomization_factor > 0.0 {
            inner = inner.with_jitter();
        }

        ExponentialBackoff {
            inner: inner.build(),
            max_elapsed_time: self.max_elapsed_time,
        }
    }
}

/// A stateful exponential backoff, mirroring the upstream `backoff` crate's `ExponentialBackoff`.
pub struct ExponentialBackoff {
    inner: backon::ExponentialBackoff,
    /// The configured retry budget; exposed so callers can surface it (e.g. in a reconnect event).
    pub max_elapsed_time: Option<Duration>,
}

impl ExponentialBackoff {
    /// Returns the next backoff delay, or `None` once the retry budget is exhausted.
    pub fn next_backoff(&mut self) -> Option<Duration> {
        self.inner.next()
    }
}
