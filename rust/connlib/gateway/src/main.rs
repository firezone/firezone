mod control;
mod messages;

use crate::control::{ControlPlane, ControlSignaler};
use crate::messages::IngressMessages;
use anyhow::Result;
use backoff::backoff::Backoff;
use backoff::ExponentialBackoffBuilder;
use boringtun::x25519::{PublicKey, StaticSecret};
use clap::Parser;
use firezone_tunnel::Tunnel;
use headless_utils::{setup_global_subscriber, CommonArgs};
use libs_common::control::PhoenixChannel;
use libs_common::messages::Key;
use libs_common::{get_device_id, get_websocket_path, sha256, Callbacks};
use rand::distributions::Alphanumeric;
use rand::Rng;
use std::sync::Arc;
use std::time::Duration;
use tracing_subscriber::layer;

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
    let external_id = sha256(device_id);

    let connect_url = get_websocket_path(
        cli.common.url,
        cli.common.secret,
        "gateway",
        &Key(PublicKey::from(&private_key).to_bytes()),
        &external_id,
        &name_suffix,
    )?;

    // This is kinda hacky, the buffer size is 1 so that we make sure that we
    // process one message at a time, blocking if a previous message haven't been processed
    // to force queue ordering.
    let (control_plane_sender, mut control_plane_receiver) = tokio::sync::mpsc::channel(1);

    let mut connection =
        PhoenixChannel::<_, IngressMessages, IngressMessages, IngressMessages>::new(
            connect_url,
            move |msg, reference| {
                let control_plane_sender = control_plane_sender.clone();
                async move {
                    tracing::trace!("Received message: {msg:?}");
                    if let Err(e) = control_plane_sender.send((msg, reference)).await {
                        tracing::warn!("Received a message after handler already closed: {e}. Probably message received during session clean up.");
                    }
                }
            },
        );

    // Used to send internal messages
    let control_signaler = ControlSignaler {
        control_signal: connection.sender_with_topic("gateway".to_owned()),
    };
    let tunnel = Tunnel::new(private_key, control_signaler.clone(), CallbackHandler).await?;

    let mut control_plane = ControlPlane {
        tunnel: Arc::new(tunnel),
        control_signaler,
    };

    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(10));
        loop {
            tokio::select! {
                Some((msg, _)) = control_plane_receiver.recv() => {
                    match msg {
                        Ok(msg) => control_plane.handle_message(msg).await?,
                        Err(_msg_reply) => todo!(),
                    }
                },
                _ = interval.tick() => control_plane.stats_event().await,
                else => break
            }
        }

        anyhow::Ok(())
    });

    tokio::spawn(async move {
        let mut exponential_backoff = ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(None)
            .build();
        loop {
            // `connection.start` calls the callback only after connecting
            tracing::debug!("Attempting connection to portal...");
            let result = connection
                .start(vec!["gateway".to_owned()], || exponential_backoff.reset())
                .await;
            tracing::warn!("Disconnected from the portal");
            if let Err(e) = &result {
                tracing::warn!(error = ?e, "Portal connection error");
            }

            let t = exponential_backoff
                .next_backoff()
                .expect("gateway backoff never ends");

            tracing::warn!(
                "Error connecting to portal, retrying in {} seconds",
                t.as_secs()
            );
            tokio::time::sleep(t).await;
        }
    });

    tracing::info!("new_session");

    tokio::signal::ctrl_c().await?;

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
}
