use anyhow::Result;
use std::path::PathBuf;

#[expect(
    clippy::unnecessary_wraps,
    reason = "Signature must match other platforms."
)]
pub fn register(_path: PathBuf) -> Result<()> {
    tracing::warn!("Deep-link registration is not implemented on macOS; skipping");

    Ok(())
}
