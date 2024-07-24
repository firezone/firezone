//! Not implemented for Linux yet

use anyhow::Result;
use futures::StreamExt as _;

const DESTINATION: &str = "org.freedesktop.NetworkManager";

const DNS_CHANGE_PATH: &str = "/org/freedesktop/resolve1";
const DNS_CHANGE_INTERFACE: &str = "org.freedesktop.DBus.Properties";
const DNS_CHANGE_SIGNAL: &str = "PropertiesChanged";

const NETWORK_CHANGE_PATH: &str = "/org/freedesktop/NetworkManager";
const NETWORK_CHANGE_INTERFACE: &str = "org.freedesktop.NetworkManager";
const NETWORK_CHANGE_SIGNAL: &str = "StateChanged";

/// Listens for changes of system-wide DNS resolvers
///
/// e.g. if you run `sudo resolvectl dns eno1 1.1.1.1` this should
/// notify.
///
/// Should be equivalent to `dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',path='/org/freedesktop/resolve1',member='PropertiesChanged'"`
pub(crate) async fn dns_notifier(_tokio_handle: tokio::runtime::Handle) -> Result<Worker> {
    Worker::new(DNS_CHANGE_PATH, DNS_CHANGE_INTERFACE, DNS_CHANGE_SIGNAL).await
}

/// Listens for changes between Wi-Fi networks
///
/// Should be similar to `dbus-monitor --system "type='signal',interface='org.freedesktop.NetworkManager',member='StateChanged'"`
pub(crate) async fn network_notifier(_tokio_handle: tokio::runtime::Handle) -> Result<Worker> {
    Worker::new(
        NETWORK_CHANGE_PATH,
        NETWORK_CHANGE_INTERFACE,
        NETWORK_CHANGE_SIGNAL,
    )
    .await
}

pub(crate) struct Worker {
    stream: zbus::proxy::SignalStream<'static>,
}

impl Worker {
    async fn new(
        path: &'static str,
        interface: &'static str,
        signal_name: &'static str,
    ) -> Result<Self> {
        let cxn = zbus::Connection::system().await?;
        let proxy = zbus::Proxy::new_owned(cxn, None, path, interface).await?;
        let stream = proxy.receive_signal(signal_name).await?;
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
