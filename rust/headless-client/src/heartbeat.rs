//! A heartbeat that logs to `INFO` at exponentially increasing intervals
//! so it won't take up much disk space
//!
//! The IPC service is quiet when signed out, and the GUI is quiet when it's in steady
//! state, so this heartbeat allows us to estimate roughly how long each process stayed
//! up when looking at user logs, using unlimited disk space per run of the app.

use crate::uptime_lib;
use std::time::Duration;
use tokio::time::{sleep_until, Instant};

/// Logs a heartbeat to `tracing::info!`. Put this in a Tokio task and forget about it.
pub async fn heartbeat() {
    let mut hb = Heartbeat::default();
    loop {
        sleep_until(hb.next_instant).await;
        let system_uptime = uptime_lib::get().ok();
        tracing::info!(?system_uptime, "Heartbeat");
        hb.tick();
    }
}

struct Heartbeat {
    next_instant: Instant,
    dur: Duration,
}

impl Default for Heartbeat {
    fn default() -> Self {
        Self {
            next_instant: Instant::now(),
            dur: Duration::from_secs(1),
        }
    }
}

impl Heartbeat {
    fn tick(&mut self) {
        self.next_instant += self.dur;
        self.dur *= 2;
    }
}

#[cfg(test)]
mod tests {
    /// Make sure this can run for a few years with no issue
    #[test]
    fn years() {
        let mut hb = super::Heartbeat::default();
        const SECONDS_PER_DAY: u64 = 86_400;
        const DAYS_PER_YEAR: u64 = 365;
        let far_future =
            hb.next_instant + std::time::Duration::from_secs(SECONDS_PER_DAY * DAYS_PER_YEAR * 50);

        // It will only print 32 lines or so for the next 50+ years
        for _ in 0..50 {
            hb.tick();
        }
        assert!(hb.next_instant > far_future);
    }
}
