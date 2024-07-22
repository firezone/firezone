use chrono::{DateTime, Utc};
use std::{
    fmt,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tracing_subscriber::fmt::{format::Writer, time::FormatTime};

#[derive(Debug, Clone)]
pub(crate) struct Clock {
    start: Instant,
    now: Arc<Mutex<(Instant, DateTime<Utc>)>>,
}

impl FormatTime for Clock {
    fn format_time(&self, w: &mut Writer<'_>) -> fmt::Result {
        let e = self.elapsed();
        write!(w, "{:3}.{:03}s", e.as_secs(), e.subsec_millis())
    }
}

impl Default for Clock {
    fn default() -> Self {
        let start = Instant::now();
        let utc_start = Utc::now();

        Self {
            start,
            now: Arc::new(Mutex::new((start, utc_start))),
        }
    }
}

impl Clock {
    pub(crate) fn now(&self) -> Instant {
        let (now, _) = *self.now.lock().unwrap();

        now
    }

    pub(crate) fn utc_now(&self) -> DateTime<Utc> {
        let (_, utc) = *self.now.lock().unwrap();

        utc
    }

    pub(crate) fn tick(&self) {
        const TICK: Duration = Duration::from_millis(10);

        let mut guard = self.now.lock().unwrap();

        guard.0 += TICK;
        guard.1 += TICK;
    }

    fn elapsed(&self) -> Duration {
        self.now().duration_since(self.start)
    }
}
