//! Remote control for the running Firezone GUI Client.

use anyhow::{Context as _, Result, bail};
use clap::Parser;
use connlib_model::ResourceView;
use gui_ipc::{ClientMsg, ServerMsg, StatusSummary};
use tokio::runtime::Runtime;

fn main() -> Result<()> {
    let cli = Cli::parse();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to build runtime")?;

    match cli.command() {
        Cmd::Status => {
            let reply = rt
                .block_on(gui_ipc::request(ClientMsg::Status))
                .context("Failed to query status")?;
            let ServerMsg::Status(status) = reply else {
                bail!("Unexpected reply: {reply:?}");
            };

            print_status(&status);
        }
        Cmd::Disconnect => {
            expect_ack(&rt, ClientMsg::Disconnect).context("Failed to disconnect")?
        }
        Cmd::SignOut => expect_ack(&rt, ClientMsg::SignOut).context("Failed to sign out")?,
        Cmd::Resources {
            command: None | Some(ResourcesCmd::List),
        } => list_resources(&rt)?,
        Cmd::InternetResource {
            command: InternetResourceCmd::Enable,
        } => expect_ack(&rt, ClientMsg::SetInternetResourceEnabled(true))
            .context("Failed to enable Internet Resource")?,
        Cmd::InternetResource {
            command: InternetResourceCmd::Disable,
        } => expect_ack(&rt, ClientMsg::SetInternetResourceEnabled(false))
            .context("Failed to disable Internet Resource")?,
    }

    Ok(())
}

#[derive(Parser)]
// The binary is built as `firezone-cli` to keep it from colliding with the GUI
// on Windows, but every install renames it, so usage lines must say `firezone`.
#[command(author, version, about = "Firezone CLI", long_about = None, bin_name = "firezone")]
struct Cli {
    #[command(subcommand)]
    command: Option<Cmd>,
}

impl Cli {
    /// Omitting the subcommand is equivalent to [`Cmd::Status`].
    fn command(self) -> Cmd {
        self.command.unwrap_or(Cmd::Status)
    }
}

// The help text is spelled out instead of taken from doc comments, which clap
// strips the trailing period from. It has to read the same as the macOS Client's.
#[derive(clap::Subcommand)]
enum Cmd {
    #[command(about = "Report the current status.")]
    Status,
    #[command(about = "Disconnect, keeping the stored token.")]
    Disconnect,
    #[command(about = "Sign out and remove the stored token.")]
    SignOut,
    #[command(about = "Inspect the Resources this Client can reach.")]
    Resources {
        #[command(subcommand)]
        command: Option<ResourcesCmd>,
    },
    #[command(about = "Turn the Internet Resource on or off.")]
    InternetResource {
        #[command(subcommand)]
        command: InternetResourceCmd,
    },
}

/// Omitting the subcommand is equivalent to [`ResourcesCmd::List`].
#[derive(clap::Subcommand)]
enum ResourcesCmd {
    #[command(about = "List the Resources this Client can reach. This is the default.")]
    List,
}

#[derive(clap::Subcommand)]
enum InternetResourceCmd {
    #[command(about = "Route traffic through the Internet Resource.")]
    Enable,
    #[command(about = "Stop routing traffic through the Internet Resource.")]
    Disable,
}

fn list_resources(rt: &Runtime) -> Result<()> {
    let reply = rt
        .block_on(gui_ipc::request(ClientMsg::ListResources))
        .context("Failed to list resources")?;
    let ServerMsg::Resources(resources) = reply else {
        bail!("Unexpected reply: {reply:?}");
    };

    print_resources(&resources);

    Ok(())
}

fn expect_ack(rt: &Runtime, msg: ClientMsg) -> Result<()> {
    let reply = rt.block_on(gui_ipc::request(msg))?;

    anyhow::ensure!(reply == ServerMsg::Ack, "Unexpected reply: {reply:?}");

    Ok(())
}

#[allow(
    clippy::print_stdout,
    reason = "the whole point of this subcommand is to print the status to stdout"
)]
fn print_status(status: &StatusSummary) {
    let mut rows = vec![("Signed in", if status.signed_in { "yes" } else { "no" })];

    if let Some(account_slug) = status.account_slug.as_deref().filter(|s| !s.is_empty()) {
        rows.push(("Account", account_slug));
    }

    rows.push((
        "Internet Resource",
        if status.internet_resource_enabled {
            "enabled"
        } else {
            "disabled"
        },
    ));

    let width = rows
        .iter()
        .map(|(label, _)| label.len())
        .max()
        .unwrap_or_default();

    for (label, value) in rows {
        println!("{label:<width$}  {value}");
    }
}

#[allow(
    clippy::print_stdout,
    reason = "the whole point of this subcommand is to print the resource list to stdout"
)]
fn print_resources(resources: &[ResourceView]) {
    let header = ["NAME", "ADDRESS", "STATUS"].map(str::to_owned);
    let rows = resources.iter().map(|resource| {
        [
            resource.name().to_owned(),
            resource.pastable().into_owned(),
            resource.status().to_string(),
        ]
    });
    let table = std::iter::once(header).chain(rows).collect::<Vec<_>>();
    let widths = std::array::from_fn::<_, 3, _>(|column| {
        table
            .iter()
            .map(|row| row[column].len())
            .max()
            .unwrap_or_default()
    });

    for row in table {
        let line = row
            .iter()
            .zip(widths)
            .map(|(cell, width)| format!("{cell:<width$}"))
            .collect::<Vec<_>>()
            .join("  ");

        println!("{}", line.trim_end());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(args: &[&str]) -> Cmd {
        Cli::parse_from(args).command()
    }

    #[test]
    fn no_subcommand_prints_the_status() {
        assert!(matches!(command(&["firezone"]), Cmd::Status));
    }

    #[test]
    fn subcommands() {
        assert!(matches!(command(&["firezone", "status"]), Cmd::Status));
        assert!(matches!(
            command(&["firezone", "disconnect"]),
            Cmd::Disconnect
        ));
        assert!(matches!(command(&["firezone", "sign-out"]), Cmd::SignOut));
        assert!(matches!(
            command(&["firezone", "resources"]),
            Cmd::Resources { command: None }
        ));
        assert!(matches!(
            command(&["firezone", "resources", "list"]),
            Cmd::Resources {
                command: Some(ResourcesCmd::List)
            }
        ));
        assert!(matches!(
            command(&["firezone", "internet-resource", "enable"]),
            Cmd::InternetResource {
                command: InternetResourceCmd::Enable
            }
        ));
        assert!(matches!(
            command(&["firezone", "internet-resource", "disable"]),
            Cmd::InternetResource {
                command: InternetResourceCmd::Disable
            }
        ));
    }
}
