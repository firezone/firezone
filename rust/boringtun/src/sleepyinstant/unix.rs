use std::time::Duration;

use nix::sys::time::TimeSpec;
use nix::time::{clock_gettime, ClockId};

#[cfg(any(target_os = "macos", target_os = "ios", target_os = "tvos"))]
const CLOCK_ID: ClockId = ClockId::CLOCK_MONOTONIC;
#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "tvos")))]
const CLOCK_ID: ClockId = ClockId::CLOCK_BOOTTIME;

#[derive(Clone, Copy, Debug)]
pub(crate) struct Instant {
    t: TimeSpec,
}

impl Instant {
    pub(crate) fn now() -> Self {
        // std::time::Instant unwraps as well, so feel safe doing so here
        let t = clock_gettime(CLOCK_ID).unwrap();
        Self { t }
    }

    fn checked_duration_since(&self, earlier: Instant) -> Option<Duration> {
        const NANOSECOND: nix::libc::c_long = 1_000_000_000;
        let (tv_sec, tv_nsec) = if self.t.tv_nsec() < earlier.t.tv_nsec() {
            (
                self.t.tv_sec() - earlier.t.tv_sec() - 1,
                self.t.tv_nsec() - earlier.t.tv_nsec() + NANOSECOND,
            )
        } else {
            (
                self.t.tv_sec() - earlier.t.tv_sec(),
                self.t.tv_nsec() - earlier.t.tv_nsec(),
            )
        };

        if tv_sec < 0 {
            None
        } else {
            Some(Duration::new(tv_sec as _, tv_nsec as _))
        }
    }

    pub(crate) fn duration_since(&self, earlier: Instant) -> Duration {
        self.checked_duration_since(earlier)
            .unwrap_or(Duration::ZERO)
    }
}
