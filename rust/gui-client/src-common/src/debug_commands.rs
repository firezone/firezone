//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use anyhow::Result;

#[derive(clap::Subcommand)]
pub(crate) enum Cmd {
    SetAutostart(SetAutostartArgs),
}

#[derive(clap::Parser)]
pub(crate) struct SetAutostartArgs {
    #[clap(action=clap::ArgAction::Set)]
    enabled: bool,
}

#[derive(clap::Parser)]
pub(crate) struct CheckTokenArgs {
    token: String,
}

#[derive(clap::Parser)]
pub(crate) struct StoreTokenArgs {
    token: String,
}

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::SetAutostart(SetAutostartArgs { enabled }) => set_autostart(enabled),
    }
}

fn set_autostart(enabled: bool) -> Result<()> {
    firezone_headless_client::setup_stdout_logging()?;
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(platform::set_autostart(enabled))?;
    Ok(())
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;

    pub(crate) async fn set_autostart(enabled: bool) -> Result<()> {
        let dir = dirs::config_local_dir()
            .context("Can't compute `config_local_dir`")?
            .join("autostart");
        let link = dir.join("firezone-client-gui.desktop");
        if enabled {
            tokio::fs::create_dir_all(&dir)
                .await
                .context("Can't create autostart dir")?;
            let target =
                std::path::Path::new("/usr/share/applications/firezone-client-gui.desktop");
            // If the link already exists, delete it
            tokio::fs::remove_file(&link).await.ok();
            tokio::fs::symlink(target, link)
                .await
                .context("Can't create autostart link")?;
            tracing::info!("Enabled autostart.");
        } else if tokio::fs::try_exists(&link) // I think this else-if is less intuitive, but Clippy insisted
            .await
            .context("Can't check if autostart link exists")?
        {
            tokio::fs::remove_file(&link)
                .await
                .context("Can't remove autostart link")?;
            tracing::info!("Disabled autostart.");
        } else {
            tracing::info!("Autostart is already disabled.");
        }
        Ok(())
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use super::*;

    #[allow(clippy::unused_async)]
    pub(crate) async fn set_autostart(_enabled: bool) -> Result<()> {
        todo!()
    }
}
