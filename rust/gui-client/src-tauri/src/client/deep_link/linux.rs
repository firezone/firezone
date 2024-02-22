//! TODO: Not implemented for Linux yet

use super::Error;
use connlib_shared::control::SecureUrl;
use secrecy::Secret;

pub(crate) struct Server {}

impl Server {
    pub(crate) fn new() -> Result<Self, Error> {
        tracing::warn!("Not implemented yet");
        // Stop Cargo from erroring
        if false {
            return Err(Error::CantListen);
        }
        Ok(Self {})
    }

    pub(crate) async fn accept(self) -> Result<Secret<SecureUrl>, Error> {
        tracing::warn!("Not implemented yet");
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(86400)).await;
        }
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
