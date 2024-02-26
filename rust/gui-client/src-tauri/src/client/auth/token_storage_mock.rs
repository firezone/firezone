//! Stores tokens in process memory
//!
//! This is used since Github's CI is struggling with `keyring-rs` on headless Linux.
//! TODO: Fix the CI

use super::Error;
use secrecy::SecretString;

pub(crate) struct TokenStorage {
    token: Option<SecretString>,
}

impl TokenStorage {
    pub(crate) fn new(_key: &'static str) -> Self {
        Self { token: None }
    }

    pub(crate) fn delete(&mut self) -> Result<(), Error> {
        self.token = None;
        Ok(())
    }

    pub(crate) fn get(&self) -> Result<Option<SecretString>, Error> {
        Ok(self.token.clone())
    }

    pub(crate) fn set(&mut self, token: SecretString) -> Result<(), Error> {
        self.token = Some(token);
        Ok(())
    }
}
