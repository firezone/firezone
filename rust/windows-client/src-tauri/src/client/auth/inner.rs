use super::Error;
use secrecy::{ExposeSecret, SecretString};

pub(crate) struct Inner {
    /// Key for secure keyrings, e.g. "dev.firezone.client/token" for releases
    /// and something else for automated tests of the auth module.
    keyring_key: &'static str,
}

impl Inner {
    pub(crate) fn new(keyring_key: &'static str) -> Self {
        Self { keyring_key }
    }

    // `&mut` is probably not needed here, but it feels like it should be
    pub(crate) fn delete_password(&mut self) -> Result<(), Error> {
        match self.keyring_entry()?.delete_password() {
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e)?,
        }
    }

    pub(crate) fn get_password(&self) -> Result<Option<SecretString>, Error> {
        match self.keyring_entry()?.get_password() {
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e.into()),
            Ok(token) => Ok(Some(SecretString::from(token))),
        }
    }

    pub(crate) fn set_password(&mut self, token: &SecretString) -> Result<(), Error> {
        self.keyring_entry()?.set_password(token.expose_secret())?;
        Ok(())
    }

    /// Returns an Entry into the OS' credential manager
    ///
    /// Anything you do in there is technically blocking I/O.
    fn keyring_entry(&self) -> Result<keyring::Entry, Error> {
        Ok(keyring::Entry::new_with_target(self.keyring_key, "", "")?)
    }
}
