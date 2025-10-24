#![expect(clippy::print_stdout, reason = "We are a CLI.")]

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.component {
        Component::Gateway {
            command: GatewayCommand::Authenticate { enable },
        } => {
            anyhow::ensure!(cfg!(target_os = "linux"), "Only supported Linux right now.");
            anyhow::ensure!(is_root(), "Must be executed as root.");

            let mut token = String::with_capacity(512); // Our tokens are ~270 characters, grab the next power of 2.

            loop {
                println!("Paste the token from the portal's deploy page:");

                let num_bytes = std::io::stdin()
                    .read_line(&mut token)
                    .context("Failed to read token from stdin")?;

                if num_bytes == 0 || token.trim().is_empty() {
                    continue;
                }

                break;
            }

            install_firezone_gateway_token(token)?;

            println!("Successfully installed token.");

            if enable {
                enable_gateway_service().context("Failed to enable `firezone-gateway.service`")?;
            }
        }
    }

    Ok(())
}

#[derive(Parser, Debug)]
#[command(name = "firezone", bin_name = "firezone", about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    component: Component,
}

#[derive(Debug, Subcommand)]
enum Component {
    Gateway {
        #[command(subcommand)]
        command: GatewayCommand,
    },
}

#[derive(Debug, Subcommand)]
enum GatewayCommand {
    Authenticate {
        /// Automatically start the `firezone-gateway.service` after the token has been installed.
        #[arg(long, default_value_t = true)]
        enable: bool,
    },
}

#[cfg(target_os = "linux")]
fn is_root() -> bool {
    nix::unistd::Uid::current().is_root()
}

#[cfg(not(target_os = "linux"))]
fn is_root() -> bool {
    true
}

#[cfg(target_os = "linux")]
fn install_firezone_gateway_token(token: String) -> Result<()> {
    std::fs::write("/etc/firezone/gateway-token", token)
        .context("Failed to write token to `/etc/firezone/gateway-token`")?;

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn install_firezone_gateway_token(token: String) -> Result<()> {
    anyhow::bail!("Not implemented")
}

#[cfg(target_os = "linux")]
fn enable_gateway_service() -> Result<()> {
    use std::process::Command;

    let output = Command::new("systemctl")
        .arg("enable")
        .arg("--now")
        .arg("firezone-gateway.service")
        .output()?;

    anyhow::ensure!(
        output.status.success(),
        "`systemctl enable` exited with {}",
        output.status
    );

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn enable_gateway_service() -> Result<()> {
    anyhow::bail!("Not implemented")
}
