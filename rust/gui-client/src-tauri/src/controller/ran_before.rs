//! Controls an on-disk flag indicating whether the user has signed in before

use anyhow::{Context as _, Result};
use std::path::PathBuf;
use tokio::fs;

/// Returns true if the flag is set
pub(crate) async fn get() -> Result<bool> {
    // Just check if the file exists. We don't use `atomicwrites` to write it,
    // so the content itself may be corrupt.
    Ok(fs::try_exists(path()?).await?)
}

/// Sets the flag to true
pub(crate) async fn set() -> Result<()> {
    let path = path()?;
    fs::create_dir_all(
        path.parent()
            .context("ran_before path should have a parent dir")?,
    )
    .await?;
    fs::write(&path, &[]).await?;
    debug_assert!(get().await?);
    Ok(())
}

fn path() -> Result<PathBuf> {
    let session_dir = bin_shared::known_dirs::session().context("Couldn't find session dir")?;
    Ok(session_dir.join("ran_before.txt"))
}
