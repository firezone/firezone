//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use anyhow::Result;

#[derive(clap::Subcommand)]
pub(crate) enum Cmd {
    SetAutostart(SetAutostartArgs),

    // Store and check a bogus debug token to make sure `keyring-rs`
    // is behaving.
    CheckToken(CheckTokenArgs),
    StoreToken(StoreTokenArgs),

    Icons,
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

const CRED_NAME: &str = "dev.firezone.client/test_BYKPFT6P/token";

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::SetAutostart(SetAutostartArgs { enabled }) => set_autostart(enabled),

        Cmd::CheckToken(CheckTokenArgs { token: expected }) => {
            assert_eq!(
                keyring::Entry::new_with_target(CRED_NAME, "", "")?.get_password()?,
                expected
            );
            Ok(())
        }
        Cmd::StoreToken(StoreTokenArgs { token }) => {
            keyring::Entry::new_with_target(CRED_NAME, "", "")?.set_password(&token)?;
            Ok(())
        }
        Cmd::Icons => {
            use crate::client::gui::system_tray::compositor::{compose};
            use std::fs::write;

            let logo: &[u8] = include_bytes!("../../icons/tray/Logo.png");
            let logo_grey: &[u8] = include_bytes!("../../icons/tray/Logo grey.png");

            let busy: &[u8] = include_bytes!("../../icons/tray/Busy layer.png");
            let signed_out: &[u8] = include_bytes!("../../icons/tray/Signed out layer.png");
            let update_ready: &[u8] = include_bytes!("../../icons/tray/Update ready layer.png");

            write("untracked/Busy.png", &compose([logo_grey, busy])?.save_png()?)?;
            write("untracked/Signed in.png", &compose([logo])?.save_png()?)?;
            write("untracked/Signed out.png", &compose([logo_grey, signed_out])?.save_png()?)?;

            write("untracked/Busy update ready.png", &compose([logo_grey, busy, update_ready])?.save_png()?)?;
            write("untracked/Signed in update ready.png", &compose([logo, update_ready])?.save_png()?)?;
            write("untracked/Signed out update ready.png", &compose([logo_grey, signed_out, update_ready])?.save_png()?)?;

            let start_instant = std::time::Instant::now();
            let _icon = compose([
                logo,
                update_ready,
            ])?;
            println!("Composed in {:?}", start_instant.elapsed());

            Ok(())
        }
    }
}

fn set_autostart(enabled: bool) -> Result<()> {
    firezone_headless_client::setup_stdout_logging()?;
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(crate::client::gui::set_autostart(enabled))?;
    Ok(())
}
