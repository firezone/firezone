//! Placeholder

use anyhow::Result;

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {}

pub(crate) fn run_debug() -> Result<()> {
    unimplemented!()
}

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
