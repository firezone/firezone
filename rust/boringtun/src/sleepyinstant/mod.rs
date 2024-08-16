#![forbid(unsafe_code)]
//! Attempts to provide the same functionality as std::time::Instant, except it
//! uses a timer which accounts for time when the system is asleep
use std::time::Duration;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as inner;

#[cfg(unix)]
mod unix;
#[cfg(unix)]
use unix as inner;

/// A measurement of a monotonically nondecreasing clock.
/// Opaque and useful only with [`Duration`].
///
/// Instants are always guaranteed, barring [platform bugs], to be no less than any previously
/// measured instant when created, and are often useful for tasks such as measuring
/// benchmarks or timing how long an operation takes.
///
/// Note, however, that instants are **not** guaranteed to be **steady**. In other
/// words, each tick of the underlying clock might not be the same length (e.g.
/// some seconds may be longer than others). An instant may jump forwards or
/// experience time dilation (slow down or speed up), but it will never go
/// backwards.
///
/// Instants are opaque types that can only be compared to one another. There is
/// no method to get "the number of seconds" from an instant. Instead, it only
/// allows measuring the duration between two instants (or comparing two
/// instants).
///
/// The size of an `Instant` struct may vary depending on the target operating
/// system.
///
#[derive(Clone, Copy, Debug)]
pub struct Instant {
    t: inner::Instant,
}

impl Instant {
    /// Returns an instant corresponding to "now".
    pub fn now() -> Self {
        Self {
            t: inner::Instant::now(),
        }
    }

    /// Returns the amount of time elapsed from another instant to this one,
    /// or zero duration if that instant is later than this one.
    ///
    /// # Panics
    ///
    /// panics when `earlier` was later than `self`.
    pub fn duration_since(&self, earlier: Instant) -> Duration {
        self.t.duration_since(earlier.t)
    }

    /// Returns the amount of time elapsed since this instant was created.
    pub fn elapsed(&self) -> Duration {
        Self::now().duration_since(*self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_increments_after_sleep() {
        let sleep_time = Duration::from_millis(10);
        let start = Instant::now();
        std::thread::sleep(sleep_time);
        assert!(start.elapsed() >= sleep_time);
    }
}
