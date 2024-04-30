//! In-process wrapper for connlib
//!
//! This is used so that Windows can keep connlib in the GUI process a little longer,
//! until the Linux process splitting is settled. Once both platforms are split,
//! this should be deleted.
//!
//! With this module, the main GUI module should have no direct dependence on connlib.
//! And some things in here will live in the tunnel process after the IPC split.
//! (It's okay to depend on trivial things like `BUNDLE_ID`)

use anyhow::{Context, Result};
use arc_swap::ArcSwap;
use connlib_client_shared::{ResourceDescription, Sockets};
use connlib_shared::{keypair, LoginUrl};
use secrecy::SecretString;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::Arc,
    time::Duration,
};
use tokio::sync::Notify;

use super::ControllerRequest;
use super::CtlrTx;

/// We have valid use cases for headless Windows clients
/// (IoT devices, point-of-sale devices, etc), so try to reconnect for 30 days if there's
/// been a partition.
const MAX_PARTITION_TIME: Duration = Duration::from_secs(60 * 60 * 24 * 30);

/// In `in_proc` this is just a stub for compatibility
///
/// In IPC it represents a connection to the IPC service
#[derive(Default)]
pub(crate) struct Connection {
    pub session: Option<Session>,
}

impl Connection {
    pub(crate) async fn sign_in(
        &mut self,
        api_url: &str,
        token: SecretString,
        callback_handler: CallbackHandler,
        tokio_handle: tokio::runtime::Handle,
    ) -> Result<()> {
        let mut connlib = sign_in(api_url, token, callback_handler.clone(), tokio_handle).await?;

        connlib
            .set_dns(crate::client::resolvers::get().unwrap_or_default())
            .await?;
        self.session = Some(Session {
            callback_handler,
            connlib,
        });
        Ok(())
    }

    pub(crate) async fn sign_out(&mut self) -> Result<()> {
        if let Some(session) = self.session.take() {
            tracing::debug!("disconnecting connlib");
            // This is redundant if the token is expired, in that case
            // connlib already disconnected itself.
            session.connlib.disconnect().await?;
        } else {
            // Might just be because we got a double sign-out or
            // the user canceled the sign-in or something innocent.
            tracing::info!("Tried to sign out but there's no session, cancelled sign-in");
        }
        Ok(())
    }
}

/// Forwards events to and from connlib
///
/// In the `in_proc` module this is just a stub. The real purpose is to abstract
/// over both in-proc connlib instances and connlib instances living in the tunnel
/// process, across an IPC boundary.
pub(crate) struct Session {
    pub callback_handler: CallbackHandler,
    pub connlib: TunnelWrapper,
}

#[derive(Clone)]
pub(crate) struct CallbackHandler {
    pub notify_controller: Arc<Notify>,
    pub ctlr_tx: CtlrTx,
    pub resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
}

pub(crate) struct TunnelWrapper {
    // Must be private since it's implementation-dependent
    session: connlib_client_shared::Session,
}

impl TunnelWrapper {
    #[allow(clippy::unused_async)]
    pub(crate) async fn disconnect(self) -> Result<()> {
        self.session.disconnect();
        Ok(())
    }

    #[allow(clippy::unused_async)]
    pub(crate) async fn reconnect(&mut self) -> Result<()> {
        self.session.reconnect();
        Ok(())
    }

    #[allow(clippy::unused_async)]
    pub(crate) async fn set_dns(&mut self, dns: Vec<IpAddr>) -> Result<()> {
        self.session.set_dns(dns);
        Ok(())
    }
}

/// Starts connlib in-process
///
/// This is `async` because the IPC version is async
#[allow(clippy::unused_async)]
async fn sign_in(
    api_url: &str,
    token: SecretString,
    callback_handler: CallbackHandler,
    tokio_handle: tokio::runtime::Handle,
) -> Result<TunnelWrapper> {
    // Device ID should be in the tunnel process
    let device_id =
        connlib_shared::device_id::get().context("Failed to read / create device ID")?;

    // Private keys should be generated in the tunnel process
    let (private_key, public_key) = keypair();

    let login = LoginUrl::client(api_url, &token, device_id.id, None, public_key.to_bytes())?;

    // Deactivate DNS control since that can prevent us from bootstrapping a connection
    // to the portal. Maybe we could bring up a sentinel resolver before
    // connecting to the portal, but right now the portal seems to need system DNS
    // for the first connection.
    connlib_shared::deactivate_dns_control()?;

    // All direct calls into connlib must be in the tunnel process
    let session = connlib_client_shared::Session::connect(
        login,
        Sockets::new(),
        private_key,
        None,
        callback_handler,
        Some(MAX_PARTITION_TIME),
        tokio_handle,
    );
    Ok(TunnelWrapper { session })
}

// Callbacks must all be non-blocking
impl connlib_client_shared::Callbacks for CallbackHandler {
    fn on_disconnect(&self, error: &connlib_client_shared::Error) {
        tracing::debug!("on_disconnect {error:?}");
        self.ctlr_tx
            .try_send(ControllerRequest::Disconnected)
            .expect("controller channel failed");
    }

    fn on_set_interface_config(&self, _: Ipv4Addr, _: Ipv6Addr, _: Vec<IpAddr>) -> Option<i32> {
        tracing::info!("on_set_interface_config");
        self.ctlr_tx
            .try_send(ControllerRequest::TunnelReady)
            .expect("controller channel failed");
        None
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) {
        tracing::debug!("on_update_resources");
        self.resources.store(resources.into());
        self.notify_controller.notify_one();
    }
}
