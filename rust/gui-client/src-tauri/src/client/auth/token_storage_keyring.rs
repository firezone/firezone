//! Implements credential storage with `keyring-rs`.
//!
//! `keyring-rs` is cross-platform but it's hard to get it working in headless Linux
//! environments like Github's CI.

use super::Error;
use secrecy::{ExposeSecret, SecretString};

pub(crate) struct TokenStorage {
    /// Key for secure keyrings, e.g. "dev.firezone.client/token" for releases
    /// and something else for automated tests of the auth module.
    keyring_key: &'static str,
}

impl TokenStorage {
    pub(crate) fn new(keyring_key: &'static str) -> Self {
        Self { keyring_key }
    }

    // `&mut` is probably not needed here, but it feels like it should be
    pub(crate) fn delete(&mut self) -> Result<(), Error> {
        match self.keyring_entry()?.delete_password() {
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e)?,
        }
    }

    pub(crate) fn get(&self) -> Result<Option<SecretString>, Error> {
        match self.keyring_entry()?.get_password() {
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e.into()),
            Ok(token) => Ok(Some(SecretString::from(token))),
        }
    }

    pub(crate) fn set(&mut self, token: SecretString) -> Result<(), Error> {
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

#[cfg(test)]
mod tests {
    #[test]
    fn test_keyring() -> anyhow::Result<()> {
        // I used this test to find that `service` is not used - We have to namespace on our own.

        let name_1 = "dev.firezone.client/test_1/token";
        let name_2 = "dev.firezone.client/test_2/token";

        keyring::Entry::new_with_target(name_1, "", "")?.set_password("test_password_1")?;

        keyring::Entry::new_with_target(name_2, "", "")?.set_password("test_password_2")?;

        let actual = keyring::Entry::new_with_target(name_1, "", "")?.get_password()?;
        let expected = "test_password_1";

        assert_eq!(actual, expected);

        keyring::Entry::new_with_target(name_1, "", "")?.delete_password()?;
        keyring::Entry::new_with_target(name_2, "", "")?.delete_password()?;

        Ok(())
    }
}
