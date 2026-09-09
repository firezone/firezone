//! The protocol a newly launched process speaks to the running Firezone GUI.

use anyhow::{Context as _, ErrorExt as _, Result};
use client_ipc::{ConnectOptions, SocketId};
use futures::{SinkExt as _, StreamExt as _};

/// IPC messages that a newly launched process (a second instance, a deep-link
/// handler or a CLI subcommand) may send to the running instance of Firezone.
#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum ClientMsg {
    Deeplink(url::Url),
    NewInstance,
    OpenTrayMenu,
    CloseTrayMenu,
    ListResources,
    SetInternetResourceEnabled(bool),
    Status,
    Disconnect,
    SignOut,
}

/// IPC messages that the running instance sends back in reply to a [`ClientMsg`].
#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum ServerMsg {
    Ack,
    Resources(Vec<connlib_model::ResourceView>),
    Status(StatusSummary),
    Error(ServerError),
}

/// Why the running instance could not carry out a [`ClientMsg`].
///
/// [`ServerError::NotConnected`] is called out on its own because the CLI reports
/// it as a plain fact rather than as a failure with a cause chain.
#[derive(Debug, PartialEq, thiserror::Error, serde::Deserialize, serde::Serialize)]
pub enum ServerError {
    #[error("Not connected.")]
    NotConnected,
    #[error("{0}")]
    Other(String),
}

/// There is no running instance of Firezone to talk to.
#[derive(Debug, thiserror::Error)]
#[error("Firezone is not running.")]
pub struct NotRunning;

/// Summary of the running instance's state, as reported to the CLI.
#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct StatusSummary {
    pub signed_in: bool,
    pub account_slug: Option<String>,
    pub actor_name: Option<String>,
    pub internet_resource_enabled: bool,
}

/// Sends one [`ClientMsg`] to the running instance and returns its reply.
///
/// # Errors
///
/// Fails if no instance is running or if the running instance replies with
/// [`ServerMsg::Error`].
pub async fn request(msg: ClientMsg) -> Result<ServerMsg> {
    let (mut read, mut write) =
        client_ipc::connect::<ServerMsg, ClientMsg>(SocketId::Gui, ConnectOptions::default())
            .await
            .map_err(|e| {
                if e.any_is::<client_ipc::NotFound>() {
                    return e.context(NotRunning);
                }

                e
            })?;

    write.send(&msg).await.context("Failed to send request")?;

    let response = read
        .next()
        .await
        .context("No response received")?
        .context("Failed to receive response")?;

    if let ServerMsg::Error(e) = response {
        return Err(e.into());
    }

    Ok(response)
}
