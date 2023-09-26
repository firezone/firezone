use anyhow::Result;
use clap::Parser;
use firezone_client_connlib::{get_device_id, Session};
use headless_utils::{block_on_ctrl_c, setup_global_subscriber, Cli, HeadlessCallbackHandler};

fn main() -> Result<()> {
    let cli = Cli::parse();
    let _guard = setup_global_subscriber(cli.log_dir);

    let device_id = get_device_id();

    let mut session =
        Session::connect(cli.url, cli.secret, device_id, HeadlessCallbackHandler).unwrap();
    tracing::info!("new_session");

    block_on_ctrl_c();

    session.disconnect(None);
    Ok(())
}
