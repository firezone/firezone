//! TODO: Not implemented for Linux yet

use super::Error;
use connlib_shared::control::SecureUrl;
use secrecy::Secret;

pub(crate) struct Server {}

impl Server {
    pub(crate) fn new() -> Result<Self, Error> {
        tracing::warn!("Not implemented yet");
        tracing::trace!(scheme = super::FZ_SCHEME, "prevents dead code warning");
        Ok(Self {})
    }

    pub(crate) async fn accept(self) -> Result<Secret<SecureUrl>, Error> {
        tracing::warn!("Deep links not implemented yet on Linux");
        futures::future::pending().await
    }
}

pub(crate) async fn open(_url: &url::Url) -> Result<(), Error> {
    tracing::warn!("Not implemented yet");
    Ok(())
}

pub(crate) fn register() -> Result<(), Error> {
    tracing::warn!("Not implemented yet");
    Ok(())
}
