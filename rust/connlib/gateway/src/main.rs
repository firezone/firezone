use crate::control::ControlSignaler;
use crate::eventloop::Eventloop;
use crate::messages::IngressMessages;
use anyhow::{Context as _, Result};
use backoff::ExponentialBackoffBuilder;
use boringtun::x25519::{PublicKey, StaticSecret};
use clap::Parser;
use firezone_tunnel::Tunnel;
use futures::{future, TryFutureExt};
use headless_utils::{setup_global_subscriber, CommonArgs};
use libs_common::messages::Key;
use libs_common::{get_device_id, get_websocket_path, sha256, Callbacks};
use rand::distributions::Alphanumeric;
use rand::Rng;
use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;
use tracing_subscriber::layer;
use url::Url;

mod control;
mod eventloop;
mod messages;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    setup_global_subscriber(layer::Identity::new());

    let device_id = get_device_id();

    let private_key = StaticSecret::random_from_rng(rand::rngs::OsRng);
    let name_suffix: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(8)
        .map(char::from)
        .collect();
    let external_id = sha256(device_id.clone());

    let connect_url = get_websocket_path(
        cli.common.url,
        cli.common.secret,
        "gateway",
        &Key(PublicKey::from(&private_key).to_bytes()),
        &external_id,
        &name_suffix,
    )?;

    tokio::spawn(backoff::future::retry_notify(
        ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(None)
            .build(),
        move || {
            connect(device_id.clone(), private_key.clone(), connect_url.clone())
                .map_err(backoff::Error::transient)
        },
        |error, t: Duration| {
            tracing::warn!(retry_in = ?t, "Error connecting to portal: {error}");
        },
    ));

    tokio::signal::ctrl_c().await?;

    Ok(())
}

async fn connect(
    device_id: String,
    private_key: StaticSecret,
    connect_url: Url,
) -> Result<Infallible> {
    // Note: This is only needed because [`Tunnel`] does not (yet) have a synchronous, poll-like interface. If it would have, ICE candidates would be emitted as events and we could just hand them to the phoenix channel.
    let (control_tx, control_rx) = tokio::sync::mpsc::channel(1);
    let signaler = ControlSignaler::new(control_tx);
    let tunnel = Arc::new(Tunnel::new(private_key, signaler, CallbackHandler).await?);

    tracing::debug!("Attempting connection to portal...");

    let mut channel = phoenix_channel::PhoenixChannel::connect(connect_url, device_id).await?;
    channel.join("gateway", ());

    let channel = loop {
        match future::poll_fn(|cx| channel.poll(cx))
            .await
            .context("portal connection failed")?
        {
            phoenix_channel::Event::JoinedRoom { topic } if topic == "relay" => {
                tracing::info!("Joined gatway room on portal")
            }
            phoenix_channel::Event::InboundMessage {
                topic,
                msg: IngressMessages::Init(init),
            } => {
                tracing::info!("Received init message from portal on topic {topic}");

                tunnel
                    .set_interface(&init.interface)
                    .await
                    .context("Failed to set interface")?;

                break channel;
            }
            other => {
                tracing::debug!("Unhandled message from portal: {other:?}");
            }
        }
    };

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
