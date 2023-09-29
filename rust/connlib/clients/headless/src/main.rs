use anyhow::Result;
use clap::Parser;
use firezone_client_connlib::{file_logger, get_device_id, Callbacks, Error, Session};
use headless_utils::{block_on_ctrl_c, setup_global_subscriber, CommonArgs};
use secrecy::SecretString;
use std::path::PathBuf;

fn main() -> Result<()> {
    let cli = Cli::parse();

    let (layer, handle) = cli.log_dir.as_deref().map(file_logger::layer).unzip();
    setup_global_subscriber(layer);

    let device_id = get_device_id();

    let mut session = Session::connect(
        cli.common.url,
        SecretString::from(cli.common.secret),
        device_id,
        CallbackHandler { handle },
    )
    .unwrap();
    tracing::info!("new_session");

    block_on_ctrl_c();

    session.disconnect(None);
    Ok(())
}

#[derive(Clone)]
struct CallbackHandler {
    handle: Option<file_logger::Handle>,
}

impl Callbacks for CallbackHandler {
    type Error = std::convert::Infallible;

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.handle
            .as_ref()?
            .roll_to_new_file()
            .unwrap_or_else(|e| {
                tracing::debug!("Failed to roll over to new file: {e}");
                let _ = self.on_error(&Error::LogFileRollError(e));

                None
            })
    }
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(flatten)]
    common: CommonArgs,

    /// File logging directory.
    #[arg(short, long, env = "FZ_LOG_DIR")]
    log_dir: Option<PathBuf>,
}
