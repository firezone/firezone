//! Implementation, Linux-specific

use super::TOKEN_ENV_KEY;
use anyhow::{Result, bail};
use bin_shared::BUNDLE_ID;
use nix::fcntl::AT_FDCWD;
use std::path::{Path, PathBuf};

// The Client currently must run as root to control DNS
// Root group and user are used to check file ownership on the token
const ROOT_GROUP: u32 = 0;
const ROOT_USER: u32 = 0;

pub(crate) fn default_token_path() -> PathBuf {
    PathBuf::from("/etc").join(BUNDLE_ID).join("token")
}

pub(crate) fn check_token_permissions(path: &Path) -> Result<()> {
    let Ok(stat) = nix::sys::stat::fstatat(AT_FDCWD, path, nix::fcntl::AtFlags::empty()) else {
        // File doesn't exist or can't be read
        tracing::info!(
            ?path,
            ?TOKEN_ENV_KEY,
            "No token found in env var or on disk"
        );
        bail!("Token file doesn't exist");
    };
    if stat.st_uid != ROOT_USER {
        bail!(
            "Token file `{}` should be owned by root user",
            path.display()
        );
    }
    if stat.st_gid != ROOT_GROUP {
        bail!(
            "Token file `{}` should be owned by root group",
            path.display()
        );
    }
    if stat.st_mode & 0o177 != 0 {
        bail!(
            "Token file `{}` should have mode 0o400 or 0x600",
            path.display()
        );
    }
    Ok(())
}

pub(crate) fn set_token_permissions(path: &Path) -> Result<()> {
    use nix::sys::stat::Mode;
    use nix::unistd::{Gid, Uid, chown};

    chown(
        path,
        Some(Uid::from_raw(ROOT_USER)),
        Some(Gid::from_raw(ROOT_GROUP)),
    )?;

    nix::sys::stat::fchmodat(
        AT_FDCWD,
        path,
        Mode::S_IRUSR | Mode::S_IWUSR,
        nix::sys::stat::FchmodatFlags::FollowSymlink,
    )?;

    Ok(())
}

/// Writes a token to the specified path with secure permissions.
/// Creates the parent directory if needed, writes the file with mode 0o600,
/// and sets ownership to root:root.
pub(crate) fn write_token(path: &Path, token: &str) -> Result<()> {
    use anyhow::Context as _;
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("Failed to create token directory")?;
    }

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .context("Failed to create token file")?;

    file.write_all(token.as_bytes())
        .context("Failed to write token to file")?;

    set_token_permissions(path)?;

    Ok(())
}

pub(crate) fn notify_service_controller() -> Result<()> {
    Ok(sd_notify::notify(true, &[sd_notify::NotifyState::Ready])?)
}
