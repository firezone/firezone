use crate::control::ControlSignaler;
use crate::eventloop::{Eventloop, PHOENIX_TOPIC};
use crate::messages::InitGateway;
use anyhow::{Context, Result};
use backoff::backoff::Backoff;
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use connlib_shared::{get_device_id, get_user_agent, login_url, Callbacks, Mode};
use firezone_tunnel::Tunnel;
use futures::future;
use headless_utils::{setup_global_subscriber, CommonArgs};
use phoenix_channel::SecureUrl;
use secrecy::{Secret, SecretString};
use std::convert::Infallible;
use std::pin::pin;
use std::sync::Arc;
use tracing_subscriber::layer;
use url::Url;

mod control;
mod eventloop;
mod messages;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    setup_global_subscriber(layer::Identity::new());

    let (connect_url, private_key) = login_url(
        Mode::Gateway,
        cli.common.url,
        SecretString::new(cli.common.secret),
        get_device_id(),
    )?;
    let tunnel = Arc::new(Tunnel::new(private_key, ControlSignaler, CallbackHandler).await?);

    let mut backoff = ExponentialBackoffBuilder::default()
        .with_max_elapsed_time(None)
        .build();

    let eventloop = async {
        loop {
            let error = match run(tunnel.clone(), connect_url.clone()).await {
                Err(e) => e,
                Ok(never) => match never {},
            };

            let t = backoff.next_backoff().expect("the exponential backoff reconnect loop should run indefinetly");
            tracing::warn!(retry_in = ?t, "Error connecting to portal: {error:#}");

            tokio::time::sleep(t).await;
        }
    };

    future::select(pin!(eventloop), pin!(tokio::signal::ctrl_c())).await;

    Ok(())
}

async fn run(
    tunnel: Arc<Tunnel<ControlSignaler, CallbackHandler>>,
    connect_url: Url,
) -> Result<Infallible> {
    let (portal, init) = phoenix_channel::init::<InitGateway, _, _>(
        Secret::new(SecureUrl::from_url(connect_url)),
        get_user_agent(),
        PHOENIX_TOPIC,
        (),
    )
    .await??;

    tunnel
        .set_interface(&init.interface)
        .await
        .context("Failed to set interface")?;

    let mut eventloop = Eventloop::new(tunnel, portal);

    future::poll_fn(|cx| eventloop.poll(cx)).await
}

#[derive(Clone)]
struct CallbackHandler;

impl Callbacks for CallbackHandler {
    type Error = Infallible;
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(flatten)]
    common: CommonArgs,
}
