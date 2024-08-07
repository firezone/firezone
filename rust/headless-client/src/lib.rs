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
use connlib_shared::callbacks;
use firezone_bin_shared::platform::DnsControlMethod;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::PathBuf,
};
use tokio::sync::mpsc;
use tracing::subscriber::set_global_default;
use tracing_subscriber::{fmt, layer::SubscriberExt as _, EnvFilter, Layer as _, Registry};

/// Generate a persistent device ID, stores it to disk, and reads it back.
pub mod device_id;
// Pub because the GUI reads the system resolvers
pub mod dns_control;
mod ipc_service;
pub mod known_dirs;
// TODO: Move to `bin-shared`?
pub mod signals;
pub mod uptime;

pub use ipc_service::{ipc, run_only_ipc_service, ClientMsg as IpcClientMsg};

pub use dns_control::DnsController;
use ip_network::{Ipv4Network, Ipv6Network};

/// Only used on Linux
pub const FIREZONE_GROUP: &str = "firezone-client";

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

/// Messages we get from connlib, including ones that aren't sent to IPC clients
pub enum InternalServerMsg {
    Ipc(IpcServerMsg),
    OnSetInterfaceConfig {
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
    },
    OnUpdateRoutes {
        ipv4: Vec<Ipv4Network>,
        ipv6: Vec<Ipv6Network>,
    },
}

/// Messages that we can send to IPC clients
#[derive(Debug, serde::Deserialize, serde::Serialize)]
pub enum IpcServerMsg {
    OnDisconnect {
        error_msg: String,
        is_authentication_error: bool,
    },
    OnUpdateResources(Vec<callbacks::ResourceDescription>),
    /// The IPC service is terminating, maybe due to a software update
    ///
    /// This is a hint that the Client should exit with a message like,
    /// "Firezone is updating, please restart the GUI" instead of an error like,
    /// "IPC connection closed".
    TerminatingGracefully,
}

#[derive(Clone)]
pub struct CallbackHandler {
    pub cb_tx: mpsc::Sender<InternalServerMsg>,
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

    fn on_set_interface_config(&self, ipv4: Ipv4Addr, ipv6: Ipv6Addr, dns: Vec<IpAddr>) {
        self.cb_tx
            .try_send(InternalServerMsg::OnSetInterfaceConfig { ipv4, ipv6, dns })
            .expect("Should be able to send OnSetInterfaceConfig");
    }

    fn on_update_resources(&self, resources: Vec<callbacks::ResourceDescription>) {
        tracing::debug!(len = resources.len(), "New resource list");
        self.cb_tx
            .try_send(InternalServerMsg::Ipc(IpcServerMsg::OnUpdateResources(
                resources,
            )))
            .expect("Should be able to send OnUpdateResources");
    }

    fn on_update_routes(&self, ipv4: Vec<Ipv4Network>, ipv6: Vec<Ipv6Network>) {
        self.cb_tx
            .try_send(InternalServerMsg::OnUpdateRoutes { ipv4, ipv6 })
            .expect("Should be able to send messages");
    }
}

/// Sets up logging for stdout only, with INFO level by default
pub fn setup_stdout_logging() -> Result<()> {
    let filter = EnvFilter::new(ipc_service::get_log_filter().context("Can't read log filter")?);
    let layer = fmt::layer().with_filter(filter);
    let subscriber = Registry::default().with(layer);
    set_global_default(subscriber)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    const EXE_NAME: &str = "firezone-client-ipc";

    // Make sure it's okay to store a bunch of these to mitigate #5880
    #[test]
    fn callback_msg_size() {
        assert_eq!(std::mem::size_of::<InternalServerMsg>(), 56)
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn dns_control() {
        let actual = CliCommon::parse_from([EXE_NAME]);
        assert!(matches!(
            actual.dns_control,
            DnsControlMethod::SystemdResolved
        ));

        let actual = CliCommon::parse_from([EXE_NAME, "--dns-control", "disabled"]);
        assert!(matches!(actual.dns_control, DnsControlMethod::Disabled));

        let actual = CliCommon::parse_from([EXE_NAME, "--dns-control", "etc-resolv-conf"]);
        assert!(matches!(
            actual.dns_control,
            DnsControlMethod::EtcResolvConf
        ));

        let actual = CliCommon::parse_from([EXE_NAME, "--dns-control", "systemd-resolved"]);
        assert!(matches!(
            actual.dns_control,
            DnsControlMethod::SystemdResolved
        ));

        assert!(CliCommon::try_parse_from([EXE_NAME, "--dns-control", "invalid"]).is_err());
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn dns_control() {
        let actual = CliCommon::parse_from([EXE_NAME]);
        assert!(matches!(actual.dns_control, DnsControlMethod::Nrpt));

        let actual = CliCommon::parse_from([EXE_NAME, "--dns-control", "disabled"]);
        assert!(matches!(actual.dns_control, DnsControlMethod::Disabled));

        let actual = CliCommon::parse_from([EXE_NAME, "--dns-control", "nrpt"]);
        assert!(matches!(actual.dns_control, DnsControlMethod::Nrpt));

        assert!(CliCommon::try_parse_from([EXE_NAME, "--dns-control", "invalid"]).is_err());
    }
}
