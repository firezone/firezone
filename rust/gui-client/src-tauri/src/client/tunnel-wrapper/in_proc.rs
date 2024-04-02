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
use connlib_client_shared::{file_logger, ResourceDescription, Sockets};
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

// This will stay in the GUI process
#[derive(Clone)]
pub(crate) struct CallbackHandler {
    // This isn't used, but maybe we need to keep it alive or something.
    pub _logger: file_logger::Handle,
    pub notify_controller: Arc<Notify>,
    pub ctlr_tx: CtlrTx,
    pub resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
}

/// Forwards events to and from connlib
///
/// In the `in_proc` module this is just a stub. The real purpose is to abstract
/// over both in-proc connlib instances and connlib instances living in the tunnel
/// process, across an IPC boundary.
pub(crate) struct TunnelWrapper {
    session: connlib_client_shared::Session,
}

impl TunnelWrapper {
    pub(crate) fn disconnect(self) {
        self.session.disconnect()
    }

    pub(crate) fn reconnect(&self) {
        self.session.reconnect()
    }

    pub(crate) fn set_dns(&self, dns: Vec<IpAddr>) {
        self.session.set_dns(dns)
    }
}

pub fn connect(
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
