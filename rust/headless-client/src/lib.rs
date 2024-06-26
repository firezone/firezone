//! A library for the privileged tunnel process for a Linux Firezone Client
//!
//! This is built both standalone and as part of the GUI package. Building it
//! standalone is faster and skips all the GUI dependencies. We can use that build for
//! CLI use cases.
//!
//! Building it as a binary within the `gui-client` package allows the
//! Tauri deb bundler to pick it up easily.
//! Otherwise we would just make it a normal binary crate.

use anyhow::{Context as _, Result};
use connlib_client_shared::{Callbacks, Error as ConnlibError};
use connlib_shared::{callbacks, Cidrv4, Cidrv6};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::PathBuf,
};
use tokio::sync::mpsc;
use tracing::subscriber::set_global_default;
use tracing_subscriber::{fmt, layer::SubscriberExt as _, EnvFilter, Layer as _, Registry};

use platform::default_token_path;
/// SIGINT and, on Linux, SIGHUP.
///
/// Must be constructed inside a Tokio runtime context.
use platform::Signals;

/// Generate a persistent device ID, stores it to disk, and reads it back.
pub(crate) mod device_id;
// Pub because the GUI reads the system resolvers
pub mod dns_control;
pub mod heartbeat;
mod ipc_service;
pub mod known_dirs;
mod standalone;

#[cfg(target_os = "linux")]
#[path = "linux.rs"]
pub mod platform;

#[cfg(target_os = "windows")]
#[path = "windows.rs"]
pub mod platform;

pub use ipc_service::{ipc, run_only_ipc_service, ClientMsg as IpcClientMsg};
pub use standalone::run_only_headless_client;

use dns_control::DnsController;

/// Only used on Linux
pub const FIREZONE_GROUP: &str = "firezone-client";

/// Output of `git describe` at compile time
/// e.g. `1.0.0-pre.4-20-ged5437c88-modified` where:
///
/// * `1.0.0-pre.4` is the most recent ancestor tag
/// * `20` is the number of commits since then
/// * `g` doesn't mean anything
/// * `ed5437c88` is the Git commit hash
/// * `-modified` is present if the working dir has any changes from that commit number
pub(crate) const GIT_VERSION: &str = git_version::git_version!(
    args = ["--always", "--dirty=-modified", "--tags"],
    fallback = "unknown"
);

const TOKEN_ENV_KEY: &str = "FIREZONE_TOKEN";

/// CLI args common to both the IPC service and the headless Client
#[derive(clap::Args)]
struct CliCommon {
    /// File logging directory. Should be a path that's writeable by the current user.
    #[arg(short, long, env = "LOG_DIR")]
    log_dir: Option<PathBuf>,

    /// Maximum length of time to retry connecting to the portal if we're having internet issues or
    /// it's down. Accepts human times. e.g. "5m" or "1h" or "30d".
    #[arg(short, long, env = "MAX_PARTITION_TIME")]
    max_partition_time: Option<humantime::Duration>,
}

enum InternalServerMsg {
    Ipc(IpcServerMsg),
    OnSetInterfaceConfig {
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
    },
    OnUpdateRoutes {
        ipv4: Vec<Cidrv4>,
        ipv6: Vec<Cidrv6>,
    },
}

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum IpcServerMsg {
    Ok,
    OnDisconnect {
        error_msg: String,
        is_authentication_error: bool,
    },
    OnTunnelReady,
    OnUpdateResources(Vec<callbacks::ResourceDescription>),
}

#[derive(Clone)]
struct CallbackHandler {
    cb_tx: mpsc::Sender<InternalServerMsg>,
}

impl Callbacks for CallbackHandler {
    fn on_disconnect(&self, error: &connlib_client_shared::Error) {
        tracing::error!(?error, "Got `on_disconnect` from connlib");
        let is_authentication_error = if let ConnlibError::PortalConnectionFailed(error) = error {
            error.is_authentication_error()
        } else {
            false
        };
        self.cb_tx
            .try_send(InternalServerMsg::Ipc(IpcServerMsg::OnDisconnect {
                error_msg: error.to_string(),
                is_authentication_error,
            }))
            .expect("should be able to send OnDisconnect");
    }

    fn on_set_interface_config(
        &self,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
    ) -> Option<i32> {
        tracing::info!("TunnelReady (on_set_interface_config)");
        self.cb_tx
            .try_send(InternalServerMsg::OnSetInterfaceConfig { ipv4, ipv6, dns })
            .expect("Should be able to send TunnelReady");

        None
    }

    fn on_update_resources(&self, resources: Vec<callbacks::ResourceDescription>) {
        tracing::debug!(len = resources.len(), "New resource list");
        self.cb_tx
            .try_send(InternalServerMsg::Ipc(IpcServerMsg::OnUpdateResources(
                resources,
            )))
            .expect("Should be able to send OnUpdateResources");
    }

    fn on_update_routes(&self, ipv4: Vec<Cidrv4>, ipv6: Vec<Cidrv6>) -> Option<i32> {
        self.cb_tx
            .try_send(InternalServerMsg::OnUpdateRoutes { ipv4, ipv6 })
            .expect("Should be able to send messages");
        None
    }
}

#[allow(dead_code)]
enum SignalKind {
    /// SIGHUP
    ///
    /// Not caught on Windows
    Hangup,
    /// SIGINT
    Interrupt,
}

/// Sets up logging for stdout only, with INFO level by default
pub fn setup_stdout_logging() -> Result<()> {
    let filter = EnvFilter::new(ipc_service::get_log_filter().context("Can't read log filter")?);
    let layer = fmt::layer().with_filter(filter);
    let subscriber = Registry::default().with(layer);
    set_global_default(subscriber)?;
    Ok(())
}
