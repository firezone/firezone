use std::path::PathBuf;

use anyhow::{Result, bail};
use secrecy::Secret;

pub struct Server {}

impl Server {
    pub async fn new() -> Result<Self> {
        bail!("not implemented")
    }

    pub async fn accept(self) -> Result<Option<Secret<Vec<u8>>>> {
        futures::future::pending().await
    }
}

pub async fn open(_url: &url::Url) -> Result<()> {
    Ok(())
}

pub fn register(_path: PathBuf) -> Result<()> {
    Ok(())
}
