//! Management commands for a Gateway installed from the `.deb` package.

#![expect(
    clippy::print_stdout,
    reason = "These commands talk to the user directly."
)]

use anyhow::{Context, Result};
use secrecy::{ExposeSecret as _, SecretString};

const ETC_FIREZONE_GATEWAY_TOKEN: &str = "/etc/firezone/gateway-token";

#[derive(Debug, clap::Subcommand)]
pub enum Command {
    /// Securely store the Gateway's token on disk.
    Authenticate {
        /// If an existing token is found, replace it.
        #[arg(long, default_value_t = false)]
        replace: bool,
    },
    /// Enable the Gateway's systemd service.
    EnableService,
    /// Disable the Gateway's systemd service.
    DisableService,
}

pub fn run(command: Command) -> Result<()> {
    anyhow::ensure!(
        cfg!(target_os = "linux"),
        "Only supported on Linux right now"
    );
    anyhow::ensure!(is_root(), "Must be executed as root");

    match command {
        Command::Authenticate { replace } => authenticate(replace)?,
        Command::EnableService => {
            systemctl("enable --now firezone-gateway.service")
                .context("Failed to enable `firezone-gateway.service`")?;

            println!("Successfully enabled `firezone-gateway.service`");
        }
        Command::DisableService => {
            systemctl("disable firezone-gateway.service")
                .context("Failed to disable `firezone-gateway.service`")?;

            println!("Successfully disabled `firezone-gateway.service`");
        }
    }

    Ok(())
}

fn authenticate(replace: bool) -> Result<()> {
    if let Ok(existing) = std::fs::read_to_string(ETC_FIREZONE_GATEWAY_TOKEN)
        && !existing.trim().is_empty()
        && !replace
    {
        anyhow::bail!(
            "Found existing token at {ETC_FIREZONE_GATEWAY_TOKEN}, use --replace to overwrite"
        );
    }

    let token = loop {
        println!("Paste the token from the portal's deploy page:");

        let token = rpassword::read_password().context("Failed to read token from stdin")?;

        if token.trim().is_empty() {
            continue;
        }

        break SecretString::new(token.into_boxed_str());
    };

    std::fs::write(ETC_FIREZONE_GATEWAY_TOKEN, token.expose_secret())
        .with_context(|| format!("Failed to write to `{ETC_FIREZONE_GATEWAY_TOKEN}`"))?;

    println!("Successfully installed token");
    println!("Tip: You can now start the Gateway with `firezone-gateway enable-service`");

    Ok(())
}

#[cfg(target_os = "linux")]
fn is_root() -> bool {
    nix::unistd::Uid::current().is_root()
}

#[cfg(not(target_os = "linux"))]
fn is_root() -> bool {
    true
}

fn systemctl(args: &str) -> Result<()> {
    let output = std::process::Command::new("systemctl")
        .args(args.split_ascii_whitespace())
        .output()?;

    anyhow::ensure!(
        output.status.success(),
        "`systemctl {args}` exited with {}",
        output.status
    );

    Ok(())
}
