//! Implementation, Linux-specific

use super::TOKEN_ENV_KEY;
use anyhow::{Result, bail};
use nix::fcntl::AT_FDCWD;
use std::path::Path;

// The Client currently must run as root to control DNS
// Root group and user are used to check file ownership on the token
const ROOT_GROUP: u32 = 0;
const ROOT_USER: u32 = 0;

/// Re-exec via `sudo` if we are not already root.
pub(crate) fn elevate_if_needed() -> Result<()> {
    use anyhow::Context as _;
    use std::os::unix::process::CommandExt as _;

    // Set on the re-exec'd child so we can detect and break a re-exec loop if
    // `sudo` ever returns without actually elevating us.
    const REEXEC_GUARD: &str = "FIREZONE_REEXEC_ELEVATED";

    if nix::unistd::Uid::effective().is_root() {
        return Ok(());
    }
    if std::env::var_os(REEXEC_GUARD).is_some() {
        bail!("Re-executed via `sudo` but still not root");
    }

    let exe = std::env::current_exe().context("Failed to find current executable")?;
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();

    // `-E` preserves the environment (e.g. `FIREZONE_TOKEN`, `RUST_LOG`); `--`
    // ends `sudo`'s own flags. Setting the guard via `.env` configures only the
    // child's environment.
    let err = std::process::Command::new("sudo")
        .arg("-E")
        .arg("--")
        .arg(&exe)
        .args(&args)
        .env(REEXEC_GUARD, "1")
        // `exec` replaces the current process image via `execve(2)`.
        .exec();

    Err(err).context("Failed to re-execute via `sudo`; is it installed?")
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
    Ok(sd_notify::notify(&[sd_notify::NotifyState::Ready])?)
}
