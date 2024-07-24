//! Not implemented for Linux yet

use anyhow::Result;
use tokio::time::Interval;

pub struct NetworkNotifier {}

impl NetworkNotifier {
    pub fn new() -> Result<Self> {
        Ok(Self {})
    }

    pub fn close(&mut self) -> Result<()> {
        Ok(())
    }

    /// Not implemented on Linux
    ///
    /// On Windows this returns when we gain or lose Internet.
    pub async fn notified(&mut self) {
        futures::future::pending().await
    }
}

pub struct DnsNotifier {
    interval: Interval,
}

impl DnsNotifier {
    pub fn new() -> Result<Self> {
        Ok(Self {
            interval: create_interval(),
        })
    }

    pub async fn notified(&mut self) -> Result<()> {
        self.interval.tick().await;
        Ok(())
    }
}

fn create_interval() -> Interval {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    interval
}
