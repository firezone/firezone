//! Remote control for the running Firezone GUI Client.

use crate::cli::{Cli, Cmd, InternetResourceCmd, ResourcesCmd};
use anyhow::{Context as _, ErrorExt as _, Result, bail};
use clap::Parser as _;
use connlib_model::ResourceView;
use gui_ipc::{ClientMsg, NotRunning, ServerError, ServerMsg, TunnelStatus};
use secrecy::SecretString;
use std::{
    io::{BufRead as _, IsTerminal as _},
    process::ExitCode,
};
use tokio::runtime::Runtime;
use tracing_subscriber::filter::LevelFilter;

mod cli;
#[cfg(target_os = "windows")]
mod shell;

#[allow(
    clippy::print_stderr,
    reason = "reporting the failure to the user is what this is for"
)]
fn main() -> ExitCode {
    let cli = Cli::parse();
    let debug = cli.debug;

    if debug {
        // Nothing installs a subscriber otherwise, so the `tracing` events of the
        // libraries this is built on go nowhere, which is what we want by default.
        tracing_subscriber::fmt()
            .with_max_level(LevelFilter::DEBUG)
            .with_writer(std::io::stderr)
            .init();
    }

    let Err(error) = run(cli) else {
        return ExitCode::SUCCESS;
    };

    // Under `--debug` the causes are the point.
    let message = expected(&error)
        .filter(|_| !debug)
        .unwrap_or_else(|| format!("{error:#}"));

    eprintln!("{message}");

    ExitCode::FAILURE
}

/// The message to print for a failure the user is expected to run into.
///
/// Anything else keeps its cause chain, which is what makes a bug report useful.
fn expected(error: &anyhow::Error) -> Option<String> {
    if error.any_is::<NotRunning>() {
        return Some(NotRunning.to_string());
    }

    let server_error = error.any_downcast_ref::<ServerError>()?;

    match server_error {
        ServerError::NotConnected => Some(server_error.to_string()),
        ServerError::NotSignedIn { sign_in_url } => Some(sign_in_instructions(sign_in_url)),
        ServerError::Other(_) => None,
    }
}

/// What to do about not having a token, written out so it can be followed as-is.
#[cfg(target_os = "windows")]
fn sign_in_instructions(sign_in_url: &str) -> String {
    windows_instructions(shell::Shell::detect()).render(sign_in_url)
}

/// What to do about not having a token, written out so it can be followed as-is.
#[cfg(not(target_os = "windows"))]
fn sign_in_instructions(sign_in_url: &str) -> String {
    let bin = cli::BIN_NAME;

    Instructions {
        copy_step: "Copy the token.",
        run: vec![
            format!("wl-paste | {bin} connect"),
            format!("xclip -selection clipboard -o | {bin} connect  # on X11"),
        ],
        env_var: "FIREZONE_TOKEN",
        from_file: Some(format!("{bin} connect < token")),
        store: "keyring",
    }
    .render(sign_in_url)
}

#[cfg(target_os = "windows")]
fn windows_instructions(shell: shell::Shell) -> Instructions {
    let bin = cli::BIN_NAME;

    match shell {
        shell::Shell::PowerShell => Instructions {
            copy_step: "Copy the token.",
            run: vec![format!("Get-Clipboard | {bin} connect")],
            env_var: "$env:FIREZONE_TOKEN",
            from_file: Some(format!("Get-Content token | {bin} connect")),
            store: "Credential Manager",
        },
        // cmd.exe has no command that reads the clipboard.
        shell::Shell::Cmd => Instructions {
            copy_step: "Copy the token and save it to a file named token.",
            run: vec![format!("{bin} connect < token")],
            env_var: "FIREZONE_TOKEN",
            from_file: None,
            store: "Credential Manager",
        },
    }
}

/// The parts of the sign-in instructions that differ by platform and shell.
struct Instructions {
    copy_step: &'static str,
    /// The commands that connect with the copied token, one per line.
    run: Vec<String>,
    env_var: &'static str,
    /// The command that connects with a token saved to the file `token`.
    from_file: Option<String>,
    store: &'static str,
}

impl Instructions {
    fn render(&self, sign_in_url: &str) -> String {
        let Self {
            copy_step,
            run,
            env_var,
            from_file,
            store,
        } = self;
        let run = run.join("\n     ");
        let other_sources = match from_file {
            Some(command) => format!(
                "A token can also be set in {env_var}, or read from a file:\n\n     {command}"
            ),
            None => format!("A token can also be set in {env_var}."),
        };

        format!(
            "No token found. To sign in:

  1. Open this in a browser and sign in:

     {sign_in_url}

  2. {copy_step}

  3. Run:

     {run}

{other_sources}

The token is saved in the {store}, so later runs don't need one.
Signing in from the Firezone tray menu stores a token too."
        )
    }
}

fn run(cli: Cli) -> Result<()> {
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
        Cmd::Connect => connect(&rt)?,
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

fn connect(rt: &Runtime) -> Result<()> {
    let token = supplied_token().context("Failed to read token")?;

    expect_ack(rt, ClientMsg::Connect { token }).context("Failed to connect")?;

    Ok(())
}

/// The token piped on stdin, else the one in `FIREZONE_TOKEN`, else nothing.
fn supplied_token() -> Result<Option<SecretString>> {
    if let Some(token) = piped_token().context("Failed to read stdin")? {
        tracing::debug!("Using token piped on stdin");

        return Ok(Some(SecretString::from(token)));
    }

    if let Some(token) = std::env::var("FIREZONE_TOKEN")
        .ok()
        .and_then(|value| non_empty(&value))
    {
        tracing::debug!("Using token from FIREZONE_TOKEN");

        return Ok(Some(SecretString::from(token)));
    }

    tracing::debug!("No token supplied, the GUI uses the stored one");

    Ok(None)
}

/// The first line piped on stdin.
///
/// Nothing is read from a terminal: with no pipe there is nothing waiting, and
/// asking would just block.
fn piped_token() -> Result<Option<String>> {
    let stdin = std::io::stdin();

    if stdin.is_terminal() {
        return Ok(None);
    }

    let mut line = String::new();
    stdin.lock().read_line(&mut line)?;

    Ok(non_empty(&line))
}

/// The trimmed value, unless nothing is left of it.
///
/// A leading BOM goes too: PowerShell 5.1's `Set-Content -Encoding utf8` writes
/// one, and it is not whitespace.
fn non_empty(value: &str) -> Option<String> {
    let value = value.trim_start_matches('\u{FEFF}').trim();

    (!value.is_empty()).then(|| value.to_owned())
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
fn print_status(status: &TunnelStatus) {
    println!("{}", status_line(status));
}

/// The status as one sentence, naming only what the portal supplied.
fn status_line(status: &TunnelStatus) -> String {
    let (account_slug, actor_name) = match status {
        TunnelStatus::Disconnected => return "Not connected.".to_owned(),
        TunnelStatus::Connecting => return "Connecting...".to_owned(),
        TunnelStatus::Connected {
            account_slug,
            actor_name,
        } => (account_slug, actor_name),
    };

    let account = account_slug.as_deref().filter(|s| !s.is_empty());
    let user = actor_name.as_deref().filter(|s| !s.is_empty());

    match (account, user) {
        (Some(account), Some(user)) => format!("Signed in to {account} as {user}."),
        (Some(account), None) => format!("Signed in to {account}."),
        (None, Some(user)) => format!("Signed in as {user}."),
        (None, None) => "Signed in.".to_owned(),
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
    fn status_of_a_signed_in_client() {
        let line = status_line(&TunnelStatus::Connected {
            account_slug: Some("acme".to_owned()),
            actor_name: Some("Jane Doe".to_owned()),
        });

        assert_eq!(line, "Signed in to acme as Jane Doe.");
    }

    #[test]
    fn status_of_a_signed_in_client_the_portal_did_not_name() {
        let line = status_line(&TunnelStatus::Connected {
            account_slug: Some("acme".to_owned()),
            actor_name: None,
        });

        assert_eq!(line, "Signed in to acme.");
    }

    #[test]
    fn status_of_a_connecting_client() {
        assert_eq!(status_line(&TunnelStatus::Connecting), "Connecting...");
    }

    #[test]
    fn status_of_a_disconnected_client() {
        assert_eq!(status_line(&TunnelStatus::Disconnected), "Not connected.");
    }

    #[test]
    fn token_is_trimmed_of_whitespace_and_bom() {
        assert_eq!(non_empty("\u{FEFF}abc\r\n"), Some("abc".to_owned()));
        assert_eq!(non_empty("\u{FEFF}\n"), None);
        assert_eq!(non_empty("   "), None);
    }

    #[cfg(not(target_os = "windows"))]
    #[test]
    fn sign_in_instructions_name_the_url_and_the_commands() {
        let text = sign_in_instructions("https://example.com/acme?as=headless-client");

        assert!(text.contains("     https://example.com/acme?as=headless-client\n"));
        assert!(text.contains("wl-paste | firezone connect"));
        assert!(text.contains("xclip -selection clipboard -o | firezone connect"));
        assert!(text.contains("FIREZONE_TOKEN"));
        assert!(text.contains("firezone connect < token"));
        assert!(text.contains("keyring"));
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn powershell_instructions_name_the_url_and_the_commands() {
        let text = windows_instructions(shell::Shell::PowerShell)
            .render("https://example.com/acme?as=headless-client");

        assert!(text.contains("     https://example.com/acme?as=headless-client\n"));
        assert!(text.contains("Get-Clipboard | firezone connect"));
        assert!(text.contains("$env:FIREZONE_TOKEN"));
        assert!(text.contains("Get-Content token | firezone connect"));
        assert!(text.contains("Credential Manager"));
        assert!(!text.contains("< token"));
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn cmd_instructions_name_the_url_and_the_commands() {
        let text = windows_instructions(shell::Shell::Cmd)
            .render("https://example.com/acme?as=headless-client");

        assert!(text.contains("     https://example.com/acme?as=headless-client\n"));
        assert!(text.contains("firezone connect < token"));
        assert!(text.contains("A token can also be set in FIREZONE_TOKEN."));
        assert!(text.contains("Credential Manager"));
        assert!(!text.contains("Get-Clipboard"));
    }

    #[test]
    fn no_subcommand_prints_the_status() {
        assert!(matches!(command(&["firezone"]), Cmd::Status));
    }

    #[test]
    fn subcommands() {
        assert!(matches!(command(&["firezone", "status"]), Cmd::Status));
        assert!(matches!(command(&["firezone", "connect"]), Cmd::Connect));
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
