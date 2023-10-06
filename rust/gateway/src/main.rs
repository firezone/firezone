use crate::control::ControlSignaler;
use crate::eventloop::{Eventloop, PHOENIX_TOPIC};
use crate::messages::InitGateway;
use anyhow::{Context as _, Result};
use backoff::ExponentialBackoffBuilder;
use boringtun::x25519::StaticSecret;
use clap::Parser;
use connlib_shared::{get_device_id, get_user_agent, login_url, Callbacks, Mode};
use firezone_tunnel::Tunnel;
use futures::{future, TryFutureExt};
use headless_utils::{setup_global_subscriber, CommonArgs};
use phoenix_channel::SecureUrl;
use secrecy::{Secret, SecretString};
use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;
use tracing_subscriber::layer;

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

    tokio::spawn(backoff::future::retry_notify(
        ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(None)
            .build(),
        move || {
            connect(
                private_key.clone(),
                Secret::new(SecureUrl::from_url(connect_url.clone())),
            )
            .map_err(backoff::Error::transient)
        },
        |error, t: Duration| {
            tracing::warn!(retry_in = ?t, "Error connecting to portal: {error}");
        },
    ));

    tokio::signal::ctrl_c().await?;

    Ok(())
}

async fn connect(private_key: StaticSecret, connect_url: Secret<SecureUrl>) -> Result<Infallible> {
    // Note: This is only needed because [`Tunnel`] does not (yet) have a synchronous, poll-like interface. If it would have, ICE candidates would be emitted as events and we could just hand them to the phoenix channel.
    let (control_tx, control_rx) = tokio::sync::mpsc::channel(1);
    let signaler = ControlSignaler::new(control_tx);
    let tunnel = Arc::new(Tunnel::new(private_key, signaler, CallbackHandler).await?);

    tracing::debug!("Attempting connection to portal...");

    let (channel, init) = phoenix_channel::init::<InitGateway, _, _>(
        connect_url,
        get_user_agent(),
        PHOENIX_TOPIC,
        (),
    )
    .await??;

    tracing::info!("Received init message from portal");

    tunnel
        .set_interface(&init.interface)
        .await
        .context("Failed to set interface")?;

    let mut eventloop = Eventloop::new(tunnel, control_rx, channel);

    future::poll_fn(|cx| eventloop.poll(cx)).await
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
}
