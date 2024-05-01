//! Not implemented for Linux yet

use anyhow::Result;
use tokio::time::Interval;

pub(crate) fn run_dns_debug() -> Result<()> {
    tracing::warn!("network_changes not implemented yet on Linux");
    Ok(())
}

pub(crate) fn run_debug() -> Result<()> {
    tracing::warn!("network_changes not implemented yet on Linux");
    Ok(())
}

/// TODO: Implement for Linux
pub(crate) fn check_internet() -> Result<bool> {
    Ok(true)
}

pub(crate) struct Worker {
    interval: Interval,
}

impl Worker {
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {
            interval: create_interval(),
        })
    }

    pub(crate) fn close(&mut self) -> Result<()> {
        Ok(())
    }

    pub(crate) async fn notified(&mut self) {
        loop {
            self.interval.tick().await;
            tracing::debug!("Checking for network changes");
        }
    }
}

pub(crate) struct DnsListener {
    interval: Interval,
}

impl DnsListener {
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {
            interval: create_interval(),
        })
    }
    pub(crate) async fn notified(&mut self) -> Result<()> {
        loop {
            self.interval.tick().await;
            tracing::debug!("Checking for DNS changes");
        }
    }
}

fn create_interval() -> Interval {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    interval
}
