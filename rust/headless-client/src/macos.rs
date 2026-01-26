use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

pub(crate) fn check_token_permissions(_path: &Path) -> Result<()> {
    bail!("Not implemented")
}

pub(crate) fn set_token_permissions(_path: &Path) -> Result<()> {
    bail!("Not implemented")
}

pub(crate) fn default_token_path() -> PathBuf {
    PathBuf::from("/etc/dummy")
}

pub(crate) fn notify_service_controller() -> Result<()> {
    bail!("Not implemented")
}
