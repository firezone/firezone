use std::path::PathBuf;

use anyhow::{Result, bail};
use secrecy::Secret;

pub struct Server {}

impl Server {
    #[expect(
        clippy::unused_async,
        reason = "Signture must match other operating systems"
    )]
    pub async fn new() -> Result<Self> {
        bail!("not implemented")
    }

    pub async fn accept(self) -> Result<Option<Secret<Vec<u8>>>> {
        futures::future::pending().await
    }
}

pub async fn open(_url: &url::Url) -> Result<()> {
    bail!("not implemented")
}

pub fn register(_path: PathBuf) -> Result<()> {
    bail!("not implemented")
}
