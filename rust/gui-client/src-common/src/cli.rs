use clap::{Args, Parser};
use std::path::PathBuf;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
pub struct Cli {
    /// If true, check for updates every 30 seconds and pretend our current version is 1.0.0, so we'll always show the notification dot.
    #[arg(long, hide = true)]
    pub debug_update_check: bool,
    #[command(subcommand)]
    pub command: Option<Cmd>,

    /// Crash the `Controller` task to test error handling
    /// Formerly `--crash-on-purpose`
    #[arg(long, hide = true)]
    pub crash: bool,
    /// Error out of the `Controller` task to test error handling
    #[arg(long, hide = true)]
    pub error: bool,
    /// Panic the `Controller` task to test error handling
    #[arg(long, hide = true)]
    pub panic: bool,

    /// If true, slow down I/O operations to test how the GUI handles slow I/O
    #[arg(long, hide = true)]
    pub inject_faults: bool,
    /// If true, show a fake update notification that opens the Firezone release page when clicked
    #[arg(long, hide = true)]
    pub test_update_notification: bool,
    /// For headless CI, disable deep links and allow the GUI to run as admin
    #[arg(long, hide = true)]
    pub no_deep_links: bool,
}

#[derive(clap::Subcommand)]
pub enum Cmd {
    CrashHandlerServer {
        socket_path: PathBuf,
    },
    Debug {
        #[command(subcommand)]
        command: crate::debug_commands::Cmd,
    },
    Elevated,
    OpenDeepLink(DeepLink),
    /// SmokeTest gets its own subcommand for historical reasons.
    SmokeTest,
}

#[derive(Args)]
pub struct DeepLink {
    // TODO: Should be `Secret`?
    pub url: url::Url,
}

// The failure flags are all mutually exclusive
// TODO: I can't figure out from the `clap` docs how to do this:
// `app --fail-on-purpose crash-in-wintun-worker`
// So the failure should be an `Option<Enum>` but _not_ a subcommand.
// You can only have one subcommand per container, I've tried
#[derive(Debug)]
pub enum Failure {
    Crash,
    Error,
    Panic,
}

impl Cli {
    pub fn fail_on_purpose(&self) -> Option<Failure> {
        if self.crash {
            Some(Failure::Crash)
        } else if self.error {
            Some(Failure::Error)
        } else if self.panic {
            Some(Failure::Panic)
        } else {
            None
        }
    }
}
