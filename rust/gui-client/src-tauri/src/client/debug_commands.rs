//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use anyhow::Result;
use firezone_bin_shared::{network_changes, platform::DnsControlMethod};

#[derive(clap::Subcommand)]
pub(crate) enum Cmd {
    NetworkNotifiers,
    SetAutostart(SetAutostartArgs),

    // Store and check a bogus debug token to make sure `keyring-rs`
    // is behaving.
    CheckToken(CheckTokenArgs),
    StoreToken(StoreTokenArgs),
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
        Cmd::NetworkNotifiers => network_notifiers(),
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
    }
}

fn network_notifiers() -> Result<()> {
    firezone_headless_client::setup_stdout_logging()?;
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async {
        let mut dns =
            network_changes::new_dns_notifier(rt.handle().clone(), DnsControlMethod::default())
                .await?;
        tracing::info!("Listening...");
        loop {
            if let Err(error) = dns.notified().await {
                tracing::error!(?error, "DNS listener failed");
                dns.close()?;
                break;
            }
            tracing::info!("DNS");
        }
        Ok(())
    })
}

fn set_autostart(enabled: bool) -> Result<()> {
    firezone_headless_client::setup_stdout_logging()?;
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(crate::client::gui::set_autostart(enabled))?;
    Ok(())
}
