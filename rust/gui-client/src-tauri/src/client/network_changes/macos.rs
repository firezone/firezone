//! Placeholder

use anyhow::Result;

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {}

pub(crate) fn check_internet() -> Result<bool> {
    tracing::error!("This is not the real macOS client, so `network_changes` is not implemented");
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
        futures::future::pending().await
    }
}

pub(crate) struct DnsListener {}

impl DnsListener {
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {})
    }
    pub(crate) async fn notified(&mut self) -> Result<()> {
        futures::future::pending().await
    }
}
