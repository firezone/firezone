use std::time::Duration;
use tokio::time::Instant;
use uuid::Uuid;

pub struct Tracker {
    run_id: Uuid,
    start_time: Instant,
}

pub struct Info {
    pub run_id: Uuid,
    pub uptime: Duration,
}

impl Default for Tracker {
    fn default() -> Self {
        Self {
            start_time: Instant::now(),
            run_id: Uuid::new_v4(),
        }
    }
}

impl Tracker {
    pub fn info(&self) -> Info {
        Info {
            run_id: self.run_id,
            uptime: Instant::now() - self.start_time,
        }
    }
}
