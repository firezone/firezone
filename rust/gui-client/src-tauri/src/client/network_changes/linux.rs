//! Not implemented for Linux yet

use anyhow::Result;
use firezone_headless_client::dns_control::system_resolvers_for_gui;
use futures::StreamExt;
use std::net::IpAddr;
use tokio::time::Interval;

const DESTINATION: &str = "org.freedesktop.NetworkManager";
const PATH: &str = "/org/freedesktop/NetworkManager";
const INTERFACE: &str = "org.freedesktop.NetworkManager";
const SIGNAL_NAME: &str = "StateChanged";

/// Listens for changes between Wi-Fi networks
///
/// Should be similar to `dbus-monitor --system "type='signal',interface='org.freedesktop.NetworkManager',member='StateChanged'"`
pub(crate) async fn network_notifier(_tokio_handle: tokio::runtime::Handle) -> Result<Worker> {
    Worker::new().await
}

pub(crate) struct Worker {
    stream: zbus::proxy::SignalStream<'static>,
}

impl Worker {
    async fn new() -> Result<Self> {
        let cxn = zbus::Connection::system().await?;
        let proxy = zbus::Proxy::new_owned(cxn, DESTINATION, PATH, INTERFACE).await?;
        let stream = proxy.receive_signal(SIGNAL_NAME).await?;
        Ok(Self { stream })
    }

    pub(crate) fn close(&mut self) -> Result<()> {
        Ok(())
    }

    pub(crate) async fn notified(&mut self) {
        if self.stream.next().await.is_none() {
            futures::future::pending::<()>().await;
        }
    }
}

/// Listens for changes of DNS resolvers
///
/// Should be similar to `dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',path='/org/freedesktop/resolve1',member='PropertiesChanged'"`
pub(crate) struct DnsListener {
    interval: Interval,
    last_seen: Vec<IpAddr>,
}

impl DnsListener {
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {
            interval: create_interval(),
            last_seen: system_resolvers_for_gui().unwrap_or_default(),
        })
    }

    pub(crate) async fn notified(&mut self) -> Result<Vec<IpAddr>> {
        loop {
            self.interval.tick().await;
            tracing::trace!("Checking for DNS changes");
            let new = system_resolvers_for_gui().unwrap_or_default();
            if new != self.last_seen {
                self.last_seen.clone_from(&new);
                return Ok(new);
            }
        }
    }
}

fn create_interval() -> Interval {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    interval
}
