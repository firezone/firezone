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

    pub(crate) fn large_tick(&self) {
        self.tick(Self::LARGE_TICK);
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
