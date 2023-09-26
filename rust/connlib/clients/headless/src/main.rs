use anyhow::Result;
use clap::Parser;
use firezone_client_connlib::{get_device_id, Session};
use headless_utils::{
    block_on_ctrl_c, setup_global_subscriber, CommonArgs, HeadlessCallbackHandler,
};
use std::path::PathBuf;

fn main() -> Result<()> {
    let cli = Cli::parse();
    let _guard = setup_global_subscriber(cli.log_dir);

    let device_id = get_device_id();

    let mut session = Session::connect(
        cli.common.url,
        cli.common.secret,
        device_id,
        HeadlessCallbackHandler,
    )
    .unwrap();
    tracing::info!("new_session");

    block_on_ctrl_c();

    session.disconnect(None);
    Ok(())
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
