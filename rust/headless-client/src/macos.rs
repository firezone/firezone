use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use bin_shared::BUNDLE_ID;

// Root user and group IDs on macOS
const ROOT_USER: u32 = 0;
const ROOT_GROUP: u32 = 0;

pub(crate) fn default_token_path() -> PathBuf {
    PathBuf::from("/etc").join(BUNDLE_ID).join("token")
}

pub(crate) fn check_token_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    
    let metadata = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => {
            tracing::info!(?path, "No token found at path");
            bail!("Token file doesn't exist");
        }
    };
    
    // Check ownership - should be root
    if metadata.uid() != ROOT_USER {
        bail!(
            "Token file `{}` should be owned by root user (uid 0), found uid {}",
            path.display(),
            metadata.uid()
        );
    }
    
    if metadata.gid() != ROOT_GROUP {
        bail!(
            "Token file `{}` should be owned by root group (gid 0), found gid {}",
            path.display(),
            metadata.gid()
        );
    }
    
    // Check permissions - should be readable only by owner (0o400 or 0o600)
    let mode = metadata.mode();
    if mode & 0o177 != 0 {
        bail!(
            "Token file `{}` should have mode 0o400 or 0o600, found mode 0o{:o}",
            path.display(),
            mode & 0o777
        );
    }
    
    Ok(())
}

pub(crate) fn notify_service_controller() -> Result<()> {
    // macOS doesn't have an equivalent to systemd's sd_notify
    // If we implement a launchd service later, we could notify it here
    Ok(())
}
