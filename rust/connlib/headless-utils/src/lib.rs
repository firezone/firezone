use clap::Parser;
use ip_network::IpNetwork;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    path::PathBuf,
};
use tracing_flame::FlameSubscriber;
use tracing_subscriber::{prelude::*, Registry};

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
        tracing::trace!("Tunnel connected");
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
        tracing::trace!(message = "Resources updated", ?resource_list);
        Ok(())
    }

    fn on_disconnect(&self, error: Option<&Error>) -> Result<(), Self::Error> {
        tracing::trace!("Tunnel disconnected: {error:?}");
        // Note that we can't panic here, since we already hooked the panic to this function.
        std::process::exit(0);
    }

    fn on_error(&self, error: &Error) -> Result<(), Self::Error> {
        tracing::warn!("Encountered recoverable error: {error}");
        Ok(())
    }
}

pub fn block_on_ctrl_c() {
    let (tx, rx) = std::sync::mpsc::channel();
    ctrlc::set_handler(move || tx.send(()).expect("Could not send stop signal on channel."))
        .expect("Error setting Ctrl-C handler");
    rx.recv().expect("Could not receive ctrl-c signal");
}

pub fn setup_global_subscriber(bench: Option<PathBuf>) -> Option<impl Drop> {
    let fmt_subscriber = tracing_subscriber::fmt::Subscriber::default();

    let subscriber = Registry::default().with(fmt_subscriber);
    if let Some(path) = bench {
        let (flame_subscriber, guard) = FlameSubscriber::with_file(path).unwrap();
        let subscriber = subscriber.with(flame_subscriber);
        tracing::collect::set_global_default(subscriber).expect("Could not set global default");
        Some(guard)
    } else {
        tracing::collect::set_global_default(subscriber).expect("Could not set global default");
        None
    }
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
    /// Benchmarking path
    #[arg(short, long, env = "BENCH")]
    pub bench: Option<PathBuf>,
}
