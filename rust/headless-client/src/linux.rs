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

pub(crate) fn notify_service_controller() -> Result<()> {
    Ok(sd_notify::notify(true, &[sd_notify::NotifyState::Ready])?)
}
