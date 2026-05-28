use anyhow::Result;
use std::path::PathBuf;

pub fn register(_path: PathBuf) -> Result<()> {
    tracing::warn!("Deep-link registration is not implemented on macOS; skipping");

    Ok(())
}
