use clap::Parser;
use ip_network::IpNetwork;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    path::PathBuf,
};
use tracing_subscriber::{prelude::__tracing_subscriber_SubscriberExt, EnvFilter, Layer, Registry};

use firezone_client_connlib::{file_logger, Callbacks, Error, ResourceDescription, WorkerGuard};
use url::Url;

#[derive(Clone)]
pub struct HeadlessCallbackHandler;

impl Callbacks for HeadlessCallbackHandler {
    type Error = std::convert::Infallible;

    fn on_set_interface_config(
        &self,
        _tunnel_address_v4: Ipv4Addr,
        _tunnel_address_v6: Ipv6Addr,
        _dns_address: Ipv4Addr,
        _dns_fallback_strategy: String,
    ) -> Result<RawFd, Self::Error> {
        Ok(-1)
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        tracing::trace!("tunnel_connected");
        Ok(())
    }

    fn on_add_route(&self, _route: IpNetwork) -> Result<(), Self::Error> {
        Ok(())
    }

    fn on_remove_route(&self, _route: IpNetwork) -> Result<(), Self::Error> {
        Ok(())
    }

    fn on_update_resources(
        &self,
        resource_list: Vec<ResourceDescription>,
    ) -> Result<(), Self::Error> {
        tracing::trace!(?resource_list, "resource_updated");
        Ok(())
    }

    fn on_disconnect(&self, error: Option<&Error>) -> Result<(), Self::Error> {
        tracing::trace!(error = ?error, "tunnel_disconnected");
        // Note that we can't panic here, since we already hooked the panic to this function.
        std::process::exit(0);
    }

    fn on_error(&self, error: &Error) -> Result<(), Self::Error> {
        tracing::warn!(error = ?error);
        Ok(())
    }
}

pub fn block_on_ctrl_c() {
    let (tx, rx) = std::sync::mpsc::channel();
    ctrlc::set_handler(move || tx.send(()).expect("Could not send stop signal on channel."))
        .expect("Error setting Ctrl-C handler");
    rx.recv().expect("Could not receive ctrl-c signal");
}

pub fn setup_global_subscriber(
    log_dir: Option<PathBuf>,
) -> Option<(WorkerGuard, file_logger::Handle)> {
    let fmt_subscriber =
        tracing_subscriber::fmt::layer().with_filter(EnvFilter::from_default_env());
    let guard = if let Some(log_dir) = log_dir {
        let (file_logger, guard, handle) =
            file_logger::layer(&log_dir, EnvFilter::from_default_env());

        let subscriber = Registry::default().with(fmt_subscriber).with(file_logger);
        tracing::subscriber::set_global_default(subscriber).expect("Could not set global default");

        Some((guard, handle))
    } else {
        let subscriber = Registry::default().with(fmt_subscriber);
        tracing::subscriber::set_global_default(subscriber).expect("Could not set global default");
        None
    };

    guard
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
pub struct Cli {
    /// Portal's websocket url
    #[arg(short, long, env = "FZ_URL")]
    pub url: Url,
    /// Service token
    #[arg(short, long, env = "FZ_SECRET")]
    pub secret: String,
    /// File logging directory optionally
    #[arg(short, long, env = "FZ_LOG_DIR")]
    pub log_dir: Option<PathBuf>,
}
