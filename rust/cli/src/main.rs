#![expect(clippy::print_stdout, reason = "We are a CLI.")]
#![expect(clippy::print_stderr, reason = "We are a CLI.")]

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

fn main() {
    let cli = Cli::parse();

    match try_main(cli) {
        Ok(()) => {}
        Err(e) => {
            eprintln!("{e:?}")
        }
    }
}

fn try_main(cli: Cli) -> Result<()> {
    match cli.component {
        Component::Gateway {
            command: GatewayCommand::Authenticate,
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
    Authenticate,
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
    bail!("Not implemented")
}
