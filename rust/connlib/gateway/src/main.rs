use anyhow::Result;
use clap::Parser;
use firezone_gateway_connlib::{get_device_id, Session};
use headless_utils::{
    block_on_ctrl_c, setup_global_subscriber, CommonArgs, HeadlessCallbackHandler,
};
use tracing_subscriber::layer;

fn main() -> Result<()> {
    let cli = Cli::parse();
    setup_global_subscriber(layer::Identity::new());

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
}
