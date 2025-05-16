//! Not implemented for Linux yet

use crate::DnsControlMethod;
use anyhow::Result;
use futures::StreamExt as _;
use std::time::Duration;
use tokio::time::{Interval, MissedTickBehavior};

/// Parameters to tell `zbus` how to listen for a signal.
struct SignalParams {
    /// Destination, better called "peer".
    ///
    /// We don't send any data into the bus, but this tells `zbus` who
    /// we expect to hear broadcasts from
    dest: &'static str,
    path: &'static str,
    /// "Interface" in DBus terms means like a Rust trait.
    ///
    /// Currently we don't process the data, we just notify when the signal comes in, so this doesn't matter much.
    interface: &'static str,
    /// The name of the signal we care about.
    member: &'static str,
}

/// Listens for changes of system-wide DNS resolvers
///
/// e.g. if you run `sudo resolvectl dns eno1 1.1.1.1` this should
/// notify.
///
/// Should be equivalent to `dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',path='/org/freedesktop/resolve1',member='PropertiesChanged'"`
pub async fn new_dns_notifier(
    _tokio_handle: tokio::runtime::Handle,
    method: DnsControlMethod,
) -> Result<Worker> {
    match method {
        DnsControlMethod::Disabled | DnsControlMethod::EtcResolvConf => {
            Ok(Worker::new_dns_poller())
        }
        DnsControlMethod::SystemdResolved => {
            Worker::new_dbus(SignalParams {
                dest: "org.freedesktop.resolve1",
                path: "/org/freedesktop/resolve1",
                interface: "org.freedesktop.DBus.Properties",
                member: "PropertiesChanged",
            })
            .await
        }
    }
}

/// Listens for changes between Wi-Fi networks
///
/// Should be similar to `dbus-monitor --system "type='signal',interface='org.freedesktop.NetworkManager',member='StateChanged'"`
pub async fn new_network_notifier(
    _tokio_handle: tokio::runtime::Handle,
    method: DnsControlMethod,
) -> Result<Worker> {
    match method {
        DnsControlMethod::Disabled | DnsControlMethod::EtcResolvConf => Ok(Worker {
            just_started: true,
            inner: Inner::Null,
        }),
        DnsControlMethod::SystemdResolved => {
            Worker::new_dbus(SignalParams {
                dest: "org.freedesktop.NetworkManager",
                path: "/org/freedesktop/NetworkManager",
                interface: "org.freedesktop.NetworkManager",
                member: "StateChanged",
            })
            .await
        }
    }
}

pub struct Worker {
    just_started: bool,
    inner: Inner,
}

enum Inner {
    DBus(Box<zbus::proxy::SignalStream<'static>>),
    DnsPoller(Interval),
    Null,
}

impl Worker {
    fn new_dns_poller() -> Self {
        let mut interval = tokio::time::interval(Duration::from_secs(5));
        interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
        Self {
            just_started: true,
            inner: Inner::DnsPoller(interval),
        }
    }

    async fn new_dbus(params: SignalParams) -> Result<Self> {
        let SignalParams {
            dest,
            path,
            interface,
            member,
        } = params;

        let cxn = zbus::Connection::system().await?;
        let proxy = zbus::Proxy::new_owned(cxn, dest, path, interface).await?;
        let stream = proxy.receive_signal(member).await?;
        Ok(Self {
            just_started: true,
            inner: Inner::DBus(Box::new(stream)),
        })
    }

    // Needed to match Windows
    pub fn close(self) -> Result<()> {
        Ok(())
    }

    pub async fn notified(&mut self) -> Result<()> {
        if self.just_started {
            self.just_started = false;
            return Ok(());
        }
        match &mut self.inner {
            Inner::DnsPoller(interval) => {
                interval.tick().await;
            }
            Inner::DBus(stream) => {
                if stream.next().await.is_none() {
                    futures::future::pending::<()>().await;
                }
                tracing::debug!("DBus notified us");
            }
            Inner::Null => futures::future::pending::<()>().await,
        }
        Ok(())
    }
}
