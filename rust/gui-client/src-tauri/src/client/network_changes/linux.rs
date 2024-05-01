//! Not implemented for Linux yet

use anyhow::Result;
use std::net::IpAddr;
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

pub(crate) struct Worker {}

impl Worker {
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {})
    }

    pub(crate) fn close(&mut self) -> Result<()> {
        Ok(())
    }

    /// Not implemented on Linux
    ///
    /// On Windows this returns when we gain or lose Internet.
    pub(crate) async fn notified(&mut self) {
        futures::future::pending().await
    }
}

pub(crate) struct DnsListener {
    interval: Interval,
    last_seen: Vec<IpAddr>,
}

impl DnsListener {
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {
            interval: create_interval(),
            last_seen: crate::client::resolvers::get().unwrap_or_default(),
        })
    }

    pub(crate) async fn notified(&mut self) -> Result<Vec<IpAddr>> {
        loop {
            self.interval.tick().await;
            tracing::trace!("Checking for DNS changes");
            let new = crate::client::resolvers::get().unwrap_or_default();
            if new != self.last_seen {
                self.last_seen = new.clone();
                return Ok(new);
            }
        }
    }
}

fn create_interval() -> Interval {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    interval
}
