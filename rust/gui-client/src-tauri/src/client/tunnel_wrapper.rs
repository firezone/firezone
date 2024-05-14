use crate::client::gui::{ControllerRequest, CtlrTx};
use anyhow::{Context as _, Result};
use arc_swap::ArcSwap;
use connlib_client_shared::ResourceDescription;
use firezone_headless_client::IpcClientMsg;

use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::Arc,
};
use tokio::sync::Notify;

pub(crate) use imp::{connect, TunnelWrapper};

#[cfg(target_os = "linux")]
#[path = "tunnel_wrapper/linux.rs"]
mod imp;

// Stub only
#[cfg(target_os = "macos")]
#[path = "tunnel_wrapper/macos.rs"]
mod imp;

#[cfg(target_os = "windows")]
#[path = "tunnel_wrapper/windows.rs"]
mod imp;

#[derive(Clone)]
pub(crate) struct CallbackHandler {
    pub notify_controller: Arc<Notify>,
    pub ctlr_tx: CtlrTx,
    pub resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
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

impl TunnelWrapper {
    pub(crate) async fn reconnect(&mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Reconnect)
            .await
            .context("Couldn't send Reconnect")?;
        Ok(())
    }

    /// Tell connlib about the system's default resolvers
    pub(crate) async fn set_dns(&mut self, dns: Vec<IpAddr>) -> Result<()> {
        self.send_msg(&IpcClientMsg::SetDns(dns))
            .await
            .context("Couldn't send SetDns")?;
        Ok(())
    }
}
