use std::path::Path;

use anyhow::{Result, bail};

pub(crate) fn check_token_permissions(_path: &Path) -> Result<()> {
    bail!("Not implemented")
}

pub(crate) fn notify_service_controller() -> Result<()> {
    bail!("Not implemented")
}
