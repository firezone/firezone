use crate::eventloop::{Eventloop, PHOENIX_TOPIC};
use crate::messages::InitGateway;
use anyhow::{Context, Result};
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use connlib_shared::{get_user_agent, login_url, Callbacks, Mode};
use firezone_cli_utils::{setup_global_subscriber, CommonArgs};
use firezone_tunnel::{gateway, Tunnel};
use futures::{future, TryFutureExt};
use phoenix_channel::SecureUrl;
use secrecy::{Secret, SecretString};
use std::convert::Infallible;
use std::pin::pin;
use std::sync::Arc;
use tokio::signal::ctrl_c;
use tokio_tungstenite::tungstenite;
use tracing_subscriber::layer;
use url::Url;

mod eventloop;
mod messages;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    setup_global_subscriber(layer::Identity::new());

    let (connect_url, private_key) = login_url(
        Mode::Gateway,
        cli.common.api_url,
        SecretString::new(cli.common.token),
        cli.common.firezone_id,
    )?;
    let tunnel = Arc::new(Tunnel::new(private_key, CallbackHandler)?);

    let task = pin!(backoff::future::retry_notify(
        ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(None)
            .build(),
        move || run(tunnel.clone(), connect_url.clone()).map_err(to_backoff),
        |error, t| {
            tracing::warn!(retry_in = ?t, "Error connecting to portal: {error:#}");
        },
    ));
    let ctrl_c = pin!(ctrl_c().map_err(anyhow::Error::new));

    future::try_select(task, ctrl_c)
        .await
        .map_err(|e| e.factor_first().0)?;

    Ok(())
}

async fn run(
    tunnel: Arc<Tunnel<CallbackHandler, gateway::State>>,
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
        .context("Failed to set interface")?;

    let mut eventloop = Eventloop::new(tunnel, portal);

    future::poll_fn(|cx| eventloop.poll(cx))
        .await
        .context("Eventloop failed")
}

/// Maps our [`anyhow::Error`] to either a permanent or transient [`backoff`] error.
fn to_backoff(e: anyhow::Error) -> backoff::Error<anyhow::Error> {
    // As per HTTP spec, retrying client-errors without modifying the request is pointless. Thus we abort the backoff.
    if e.chain().any(is_client_error) {
        return backoff::Error::permanent(e);
    }

    backoff::Error::transient(e)
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

/// Checks whether the given [`std::error::Error`] is in-fact an HTTP error with a 4xx status code.
fn is_client_error(e: &(dyn std::error::Error + 'static)) -> bool {
    let Some(tungstenite::Error::Http(r)) = e.downcast_ref() else {
        return false;
    };

    r.status().is_client_error()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_permanent_on_client_error() {
        let error =
            anyhow::Error::new(phoenix_channel::Error::WebSocket(tungstenite::Error::Http(
                tungstenite::http::Response::builder()
                    .status(400)
                    .body(None)
                    .unwrap(),
            )));

        let backoff = to_backoff(error);

        assert!(matches!(backoff, backoff::Error::Permanent(_)))
    }
}
