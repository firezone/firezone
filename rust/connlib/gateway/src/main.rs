use anyhow::Result;
use clap::Parser;
use firezone_gateway_connlib::{get_device_id, Session};
use headless_utils::{block_on_ctrl_c, setup_global_subscriber, Cli, NoOpCallbackHandler};

fn main() -> Result<()> {
    let cli = Cli::parse();
    setup_global_subscriber();

    let device_id = get_device_id();
    let mut session =
        Session::connect(cli.url, cli.secret, device_id, None, NoOpCallbackHandler).unwrap();
    tracing::info!("Started new session");

    block_on_ctrl_c();

    session.disconnect(None);
    Ok(())
}
