//! Placeholder

use super::Error;
use connlib_shared::control::SecureUrl;
use secrecy::Secret;

pub(crate) struct Server {}

impl Server {
    pub(crate) fn new() -> Result<Self, Error> {
        tracing::warn!("This is not the actual Mac client");
        tracing::trace!(scheme = super::FZ_SCHEME, "prevents dead code warning");
        Ok(Self {})
    }

    pub(crate) async fn accept(self) -> Result<Secret<SecureUrl>, Error> {
        futures::future::pending().await
    }
}

pub(crate) async fn open(_url: &url::Url) -> Result<(), Error> {
    Ok(())
}

pub(crate) fn register() -> Result<(), Error> {
    Ok(())
}
