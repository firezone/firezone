use clap::Parser;
use ip_network::IpNetwork;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
};
use tracing_subscriber::EnvFilter;

use firezone_client_connlib::{Callbacks, Error, ResourceDescription};
use url::Url;

#[derive(Clone)]
pub struct NoOpCallbackHandler;

impl Callbacks for NoOpCallbackHandler {
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

pub fn setup_global_subscriber() {
    let fmt_subscriber = tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .finish();

    tracing::subscriber::set_global_default(fmt_subscriber).expect("Could not set global default");
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
}
