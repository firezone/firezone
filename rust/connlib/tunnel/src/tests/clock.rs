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

impl Default for FluxCapacitor {
    fn default() -> Self {
        let start = Instant::now();
        let utc_start = Utc::now();

        Self {
            start,
            now: Arc::new(Mutex::new((start, utc_start))),
        }
    }
}

impl FluxCapacitor {
    const SMALL_TICK: Duration = Duration::from_millis(10);
    const LARGE_TICK: Duration = Duration::from_millis(100);

    pub(crate) fn now(&self) -> Instant {
        let (now, _) = *self.now.lock().unwrap();

        now
    }

    pub(crate) fn utc_now(&self) -> DateTime<Utc> {
        let (_, utc) = *self.now.lock().unwrap();

        utc
    }

    pub(crate) fn small_tick(&self) -> Duration {
        self.tick(Self::SMALL_TICK);

        Self::SMALL_TICK
    }

    pub(crate) fn large_tick(&self) -> Duration {
        self.tick(Self::LARGE_TICK);

        Self::LARGE_TICK
    }

    fn tick(&self, tick: Duration) {
        let mut guard = self.now.lock().unwrap();

        guard.0 += tick;
        guard.1 += tick;
    }

    fn elapsed(&self) -> Duration {
        self.now().duration_since(self.start)
    }
}
