//! Not implemented for Linux yet

use anyhow::Result;

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {}

pub(crate) fn run_debug() -> Result<()> {
    tracing::warn!("network_changes not implemented for Linux");
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

    pub(crate) async fn notified(&self) {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(86400)).await;
        }
    }
}
