//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use anyhow::Result;
use tracing::subscriber::set_global_default;
use tracing_subscriber::{fmt, layer::SubscriberExt as _, EnvFilter, Layer, Registry};

#[derive(clap::Subcommand)]
pub(crate) enum Cmd {
    SetAutostart(SetAutostartArgs),
    TrayMenu,
}

#[derive(clap::Parser)]
pub(crate) struct SetAutostartArgs {
    #[clap(action=clap::ArgAction::Set)]
    enabled: bool,
}

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::SetAutostart(SetAutostartArgs { enabled }) => set_autostart(enabled),
        Cmd::TrayMenu => tray_menu(),
    }
}

fn set_autostart(enabled: bool) -> Result<()> {
    firezone_headless_client::setup_stdout_logging()?;
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(crate::client::gui::set_autostart(enabled))?;
    Ok(())
}

fn tray_menu() -> Result<()> {
    let filter = EnvFilter::new("debug");
    let layer = fmt::layer().with_filter(filter);
    let subscriber = Registry::default().with(layer);
    set_global_default(subscriber)?;

    let menu = crate::client::gui::system_tray_menu::debug();
    let tray = tauri::SystemTray::new().with_menu(menu);
    let app = tauri::Builder::default()
        .system_tray(tray)
        .on_system_tray_event(|_app, _event| {
            tracing::info!("System tray event");
        })
        .setup(move |_app| {
            tracing::info!("Entered Tauri's `setup`");
            Ok(())
        });
    let app = app.build(tauri::generate_context!())?;
    app.run(|_app_handle, _event| {});
    Ok(())
}
