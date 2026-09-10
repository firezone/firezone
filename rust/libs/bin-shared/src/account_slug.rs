//! Caches the account slug reported by the portal, so it is available before the next login.

use anyhow::{Context as _, Result};
use secrecy::{ExposeSecret as _, SecretString};
use sha2::Digest as _;
use std::{
    fs,
    path::{Path, PathBuf},
};

/// The account slug of the most recent successful login, cached on disk.
///
/// The cache is keyed by a hash of the token it was written with.
/// That keeps the token itself off the disk and invalidates the slug when the Gateway is pointed at a different account.
pub struct Cache {
    path: PathBuf,
    token_hash: String,
    slug: Option<String>,
}

impl Cache {
    /// Loads the Gateway's cache from `/var/lib/firezone/account_slug`.
    pub fn gateway(token: &SecretString) -> Self {
        const CACHE_PATH: &str = "/var/lib/firezone/account_slug";

        Self::at(PathBuf::from(CACHE_PATH), token)
    }

    /// Returns the cached account slug, if there is one for the current token.
    pub fn get(&self) -> Option<&str> {
        self.slug.as_deref()
    }

    /// Caches `slug` on disk, doing nothing if it is already cached.
    ///
    /// # Errors
    ///
    /// If the cache file cannot be written.
    pub fn set(&mut self, slug: &str) -> Result<()> {
        if self.slug.as_deref() == Some(slug) {
            return Ok(());
        }

        let dir = self
            .path
            .parent()
            .context("Account slug path should always have a parent")?;
        fs::create_dir_all(dir).context("Failed to create dir for account slug")?;

        let content = serde_json::to_string(&CacheJson {
            token_hash: self.token_hash.clone(),
            account_slug: slug.to_owned(),
        })
        .context("Impossible: Failed to serialize account slug")?;

        atomicfs::write(&self.path, content).context("Failed to write account slug file")?;

        self.slug = Some(slug.to_owned());

        Ok(())
    }

    fn at(path: PathBuf, token: &SecretString) -> Self {
        let token_hash = hex::encode(sha2::Sha256::digest(token.expose_secret()));

        let slug = match read_at(&path, &token_hash) {
            Ok(slug) => Some(slug),
            Err(e) => {
                tracing::debug!("No cached account slug: {e:#}");

                None
            }
        };

        Self {
            path,
            token_hash,
            slug,
        }
    }
}

fn read_at(path: &Path, token_hash: &str) -> Result<String> {
    let content = fs::read_to_string(path).context("Failed to read file")?;
    let cache = serde_json::from_str::<CacheJson>(&content)
        .context("Failed to deserialize content as JSON")?;

    anyhow::ensure!(
        cache.token_hash == token_hash,
        "Cache belongs to a different token"
    );

    Ok(cache.account_slug)
}

#[derive(serde::Deserialize, serde::Serialize)]
struct CacheJson {
    token_hash: String,
    account_slug: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn slug_is_read_back_for_the_same_token() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("account_slug");
        let mut cache = Cache::at(path.clone(), &token("some-token"));

        cache.set("acme").unwrap();

        assert_eq!(Cache::at(path, &token("some-token")).get(), Some("acme"));
    }

    #[test]
    fn slug_is_discarded_for_a_different_token() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("account_slug");
        let mut cache = Cache::at(path.clone(), &token("some-token"));

        cache.set("acme").unwrap();

        assert_eq!(Cache::at(path, &token("another-token")).get(), None);
    }

    fn token(token: &str) -> SecretString {
        SecretString::from(token)
    }
}
