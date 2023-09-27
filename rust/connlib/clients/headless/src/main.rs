use anyhow::Result;
use clap::Parser;
use firezone_client_connlib::{file_logger, get_device_id, Callbacks, Session};
use headless_utils::{block_on_ctrl_c, setup_global_subscriber, CommonArgs};
use std::path::PathBuf;

fn main() -> Result<()> {
    let cli = Cli::parse();

    let (layer, _guard, _handle) = match cli.log_dir {
        None => (None, None, None),
        Some(dir) => {
            let (layer, guard, handle) = file_logger::layer(&dir);
            (Some(layer), Some(guard), Some(handle))
        }
    };

    setup_global_subscriber(layer);

    let device_id = get_device_id();

    let mut session = Session::connect(
        cli.common.url,
        cli.common.secret,
        device_id,
        CallbackHandler,
    )
    .unwrap();
    tracing::info!("new_session");

    block_on_ctrl_c();

    session.disconnect(None);
    Ok(())
}

#[derive(Clone)]
struct CallbackHandler;

impl Callbacks for CallbackHandler {
    type Error = std::convert::Infallible;
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
