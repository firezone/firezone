use anyhow::Result;
use bin_shared::BUNDLE_ID;
use std::path::{Path, PathBuf};

// The return value is useful on Linux
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn check_token_permissions(_path: &Path) -> Result<()> {
    // TODO: Implement token permission checks on macOS
    Ok(())
}

// The return value is useful on Linux
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn set_token_permissions(_path: &Path) -> Result<()> {
    // TODO: Implement token permission setting on macOS
    Ok(())
}

/// Writes a token to the specified path with secure permissions.
/// Creates the parent directory if needed and writes the file with mode 0o600.
pub(crate) fn write_token(path: &Path, token: &str) -> Result<()> {
    use anyhow::Context as _;
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("Failed to create token directory")?;
    }

    // Create file with restrictive permissions from the start
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .context("Failed to create token file")?;

    file.write_all(token.as_bytes())
        .context("Failed to write token to file")?;

    Ok(())
}

pub(crate) fn default_token_path() -> PathBuf {
    PathBuf::from("/etc").join(BUNDLE_ID).join("token")
}

// The return value is useful on Linux
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn notify_service_controller() -> Result<()> {
    // No equivalent to sd_notify on macOS
    Ok(())
}
