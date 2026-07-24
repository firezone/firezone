use chrono::{DateTime, Utc};
use std::{
    fmt,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tracing_subscriber::fmt::{format::Writer, time::FormatTime};

/// A device that allows us to travel into the future.
#[derive(Debug, Clone)]
pub(crate) struct FluxCapacitor {
    start: Instant,
    now: Arc<Mutex<(Instant, DateTime<Utc>)>>,
}

impl FormatTime for FluxCapacitor {
    fn format_time(&self, w: &mut Writer<'_>) -> fmt::Result {
        let e = self.elapsed();
        write!(w, "{:3}.{:03}s", e.as_secs(), e.subsec_millis())
    }
}

impl FluxCapacitor {
    pub(crate) fn new(start: Instant, utc_start: DateTime<Utc>) -> Self {
        Self {
            start,
            now: Arc::new(Mutex::new((start, utc_start))),
        }
    }

    const SMALL_TICK: Duration = Duration::from_millis(10);
    const LARGE_TICK: Duration = Duration::from_millis(100);

    #[expect(private_bounds)]
    pub(crate) fn now<T>(&self) -> T
    where
        T: PickNow,
    {
        let (now, utc_now) = *self.now.lock().unwrap();

        T::pick_now(now, utc_now)
    }

    pub(crate) fn small_tick(&self) {
        self.tick(Self::SMALL_TICK);
    }

    /// Advance to the first `LARGE_TICK` grid point at or after `target` in a
    /// single step. The landing point is identical to repeatedly calling
    /// `tick(Self::LARGE_TICK)` until `now >= target`, so this only skips
    /// intermediate stops at which nothing is due.
    pub(crate) fn advance_until(&self, target: Instant) {
        let elapsed = target.saturating_duration_since(self.now::<Instant>());
        let ticks = elapsed
            .as_nanos()
            .div_ceil(Self::LARGE_TICK.as_nanos())
            .max(1);
        let ticks = u32::try_from(ticks).unwrap_or(u32::MAX);

        self.tick(Self::LARGE_TICK * ticks);
    }

    /// Jump straight to `target`, landing exactly on it, or do nothing if we are
    /// already at or past it. Unlike [`Self::advance_until`] this never advances
    /// when the target has already been reached and does not round to the grid.
    pub(crate) fn skip_to(&self, target: Instant) {
        let remaining = target.saturating_duration_since(self.now::<Instant>());

        if !remaining.is_zero() {
            self.tick(remaining);
        }
    }

    pub(crate) fn tick(&self, tick: Duration) {
        {
            let mut guard = self.now.lock().unwrap();

            guard.0 += tick;
            guard.1 += tick;
        }

        if self.elapsed().subsec_millis() == 0 {
            tracing::trace!("Tick");
        }
    }

    pub(crate) fn reset(&self) {
        let elapsed = self.elapsed();

        {
            let mut guard = self.now.lock().unwrap();

            guard.0 -= elapsed;
            guard.1 -= elapsed;
        }
    }

    fn elapsed(&self) -> Duration {
        self.now::<Instant>().duration_since(self.start)
    }
}

trait PickNow {
    fn pick_now(now: Instant, utc_now: DateTime<Utc>) -> Self;
}

impl PickNow for Instant {
    fn pick_now(now: Instant, _: DateTime<Utc>) -> Self {
        now
    }
}

impl PickNow for DateTime<Utc> {
    fn pick_now(_: Instant, utc_now: DateTime<Utc>) -> Self {
        utc_now
    }
}
