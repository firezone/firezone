//! Placeholder

use anyhow::Result;
use secrecy::Secret;

pub(crate) struct Server {}

impl Server {
    pub(crate) fn new() -> Result<Self> {
        tracing::warn!("This is not the actual Mac client");
        tracing::trace!(scheme = super::FZ_SCHEME, "prevents dead code warning");
        Ok(Self {})
    }

    pub(crate) async fn accept(self) -> Result<Option<Secret<Vec<u8>>>> {
        futures::future::pending().await
    }
}

pub(crate) async fn open(_url: &url::Url) -> Result<()> {
    Ok(())
}

pub(crate) fn register() -> Result<()> {
    Ok(())
}
