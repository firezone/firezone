use crate::control::ControlSignaler;
use crate::eventloop::{Eventloop, PHOENIX_TOPIC};
use crate::messages::InitGateway;
use anyhow::{Context, Result};
use backoff::backoff::Backoff;
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use connlib_shared::messages::ClientId;
use connlib_shared::{get_device_id, get_user_agent, login_url, Callbacks, Mode};
use firezone_tunnel::Tunnel;
use futures::future;
use headless_utils::{setup_global_subscriber, CommonArgs};
use phoenix_channel::SecureUrl;
use secrecy::{Secret, SecretString};
use std::convert::Infallible;
use std::pin::pin;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing_subscriber::layer;
use url::Url;
use webrtc::ice_transport::ice_candidate::RTCIceCandidate;

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

    // Note: This channel is only needed because [`Tunnel`] does not (yet) have a synchronous, poll-like interface. If it would have, ICE candidates would be emitted as events and we could just hand them to the phoenix channel.
    let (control_tx, mut control_rx) = mpsc::channel(1);
    let signaler = ControlSignaler::new(control_tx);
    let tunnel = Arc::new(Tunnel::new(private_key, signaler, CallbackHandler).await?);

    let mut backoff = ExponentialBackoffBuilder::default()
        .with_max_elapsed_time(None)
        .build();

    let eventloop = async {
        loop {
            let error = match run(tunnel.clone(), &mut control_rx, connect_url.clone()).await {
                Err(e) => e,
                Ok(never) => match never {},
            };

            let t = backoff.next_backoff().expect("never ends");
            tracing::warn!(retry_in = ?t, "Error connecting to portal: {error:#}");

            tokio::time::sleep(t).await;
        }
    };

    future::select(pin!(eventloop), pin!(tokio::signal::ctrl_c())).await;

    Ok(())
}

async fn run(
    tunnel: Arc<Tunnel<ControlSignaler, CallbackHandler>>,
    control_rx: &mut mpsc::Receiver<(ClientId, RTCIceCandidate)>,
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

    let mut eventloop = Eventloop::new(tunnel, control_rx, portal);

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
