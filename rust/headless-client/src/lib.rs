//! A library for the privileged tunnel process for a Linux Firezone Client
//!
//! This is built both standalone and as part of the GUI package. Building it
//! standalone is faster and skips all the GUI dependencies. We can use that build for
//! CLI use cases.
//!
//! Building it as a binary within the `gui-client` package allows the
//! Tauri deb bundler to pick it up easily.
//! Otherwise we would just make it a normal binary crate.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result};
use connlib_client_shared::Callbacks;
use connlib_model::ResourceView;
use firezone_bin_shared::platform::DnsControlMethod;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::PathBuf,
};
use tokio::sync::mpsc;
use tracing_subscriber::{fmt, layer::SubscriberExt as _, EnvFilter, Layer as _, Registry};

mod clear_logs;
/// Generate a persistent device ID, stores it to disk, and reads it back.
pub mod device_id;
// Pub because the GUI reads the system resolvers
pub mod dns_control;
mod ipc_service;
pub mod known_dirs;
// TODO: Move to `bin-shared`?
pub mod signals;
pub mod uptime;

pub use clear_logs::clear_logs;
pub use dns_control::DnsController;
pub use ipc_service::{
    ipc, run_only_ipc_service, ClientMsg as IpcClientMsg, Error as IpcServiceError,
    ServerMsg as IpcServerMsg,
};

use ip_network::{Ipv4Network, Ipv6Network};

pub type LogFilterReloader = tracing_subscriber::reload::Handle<EnvFilter, Registry>;

/// Only used on Linux
pub const FIREZONE_GROUP: &str = "firezone-client";

/// Empirically tested to have the best performance.
pub const NUM_TUN_THREADS: usize = 2;

/// CLI args common to both the IPC service and the headless Client
#[derive(clap::Parser)]
pub struct CliCommon {
    #[cfg(target_os = "linux")]
    #[arg(long, env = "FIREZONE_DNS_CONTROL", default_value = "systemd-resolved")]
    pub dns_control: DnsControlMethod,

    #[cfg(target_os = "windows")]
    #[arg(long, env = "FIREZONE_DNS_CONTROL", default_value = "nrpt")]
    pub dns_control: DnsControlMethod,

    /// File logging directory. Should be a path that's writeable by the current user.
    #[arg(short, long, env = "LOG_DIR")]
    pub log_dir: Option<PathBuf>,

    /// Maximum length of time to retry connecting to the portal if we're having internet issues or
    /// it's down. Accepts human times. e.g. "5m" or "1h" or "30d".
    #[arg(short, long, env = "MAX_PARTITION_TIME")]
    pub max_partition_time: Option<humantime::Duration>,
}

/// Messages that connlib can produce and send to the headless Client, IPC service, or GUI process.
///
/// i.e. callbacks
// The names are CamelCase versions of the connlib callbacks.
#[expect(clippy::enum_variant_names)]
pub enum ConnlibMsg {
    OnDisconnect {
        error_msg: String,
        is_authentication_error: bool,
    },
    /// Use this as `TunnelReady`, per `callbacks.rs`
    OnSetInterfaceConfig {
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
        ipv4_routes: Vec<Ipv4Network>,
        ipv6_routes: Vec<Ipv6Network>,
    },
    OnUpdateResources(Vec<ResourceView>),
}

#[derive(Clone)]
pub struct CallbackHandler {
    pub cb_tx: mpsc::Sender<ConnlibMsg>,
}

impl Callbacks for CallbackHandler {
    fn on_disconnect(&self, error: connlib_client_shared::DisconnectError) {
        self.cb_tx
            .try_send(ConnlibMsg::OnDisconnect {
                error_msg: error.to_string(),
                is_authentication_error: error.is_authentication_error(),
            })
            .expect("should be able to send OnDisconnect");
    }

    fn on_set_interface_config(
        &self,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
        ipv4_routes: Vec<Ipv4Network>,
        ipv6_routes: Vec<Ipv6Network>,
    ) {
        self.cb_tx
            .try_send(ConnlibMsg::OnSetInterfaceConfig {
                ipv4,
                ipv6,
                dns,
                ipv4_routes,
                ipv6_routes,
            })
            .expect("Should be able to send OnSetInterfaceConfig");
    }

    fn on_update_resources(&self, resources: Vec<ResourceView>) {
        tracing::debug!(len = resources.len(), "New resource list");
        self.cb_tx
            .try_send(ConnlibMsg::OnUpdateResources(resources))
            .expect("Should be able to send OnUpdateResources");
    }
}

/// Sets up logging for stdout only, with INFO level by default
pub fn setup_stdout_logging() -> Result<LogFilterReloader> {
    let directives = ipc_service::get_log_filter().context("Can't read log filter")?;
    let (filter, reloader) =
        tracing_subscriber::reload::Layer::new(firezone_logging::try_filter(&directives)?);
    let layer = fmt::layer()
        .event_format(firezone_logging::Format::new())
        .with_filter(filter);
    let subscriber = Registry::default().with(layer);
    firezone_logging::init(subscriber)?;

    Ok(reloader)
}

#[cfg(test)]
mod tests {
    use super::*;
    // Make sure it's okay to store a bunch of these to mitigate #5880
    #[test]
    fn callback_msg_size() {
        assert_eq!(std::mem::size_of::<ConnlibMsg>(), 96)
    }
}
