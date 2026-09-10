// Included verbatim by `build.rs`, which generates the shell completions from
// this `Command` without linking the binary. That rules out anything here
// referring to the rest of the crate.

use clap::Parser;

#[derive(Parser)]
// The binary is built as `firezone-cli` to keep it from colliding with the GUI
// on Windows, but every install renames it, so usage lines must say `firezone`.
#[command(author, version, about = "Firezone CLI", long_about = None, bin_name = BIN_NAME)]
pub struct Cli {
    #[arg(long, global = true, help = "Mirror the internal log to stderr.")]
    pub debug: bool,

    #[command(subcommand)]
    command: Option<Cmd>,
}

/// The name every install gives the binary, and so the name the completions
/// have to be generated and installed under.
pub const BIN_NAME: &str = "firezone";

impl Cli {
    /// Omitting the subcommand is equivalent to [`Cmd::Status`].
    pub fn command(self) -> Cmd {
        self.command.unwrap_or(Cmd::Status)
    }
}

// The help text is spelled out instead of taken from doc comments, which clap
// strips the trailing period from. It has to read the same as the macOS Client's.
#[derive(clap::Subcommand)]
pub enum Cmd {
    #[command(about = "Report the current status.")]
    Status,
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
pub enum ResourcesCmd {
    #[command(about = "List the Resources this Client can reach. This is the default.")]
    List,
}

#[derive(clap::Subcommand)]
pub enum InternetResourceCmd {
    #[command(about = "Route traffic through the Internet Resource.")]
    Enable,
    #[command(about = "Stop routing traffic through the Internet Resource.")]
    Disable,
}
