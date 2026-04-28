//! Network change detection for Linux via DBus / NetworkManager

use crate::DnsControlMethod;
use anyhow::Result;
use futures::StreamExt as _;
use std::{collections::HashMap, pin::Pin, time::Duration};
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
            Worker::new_dbus(
                SignalParams {
                    dest: "org.freedesktop.resolve1",
                    path: "/org/freedesktop/resolve1",
                    interface: "org.freedesktop.DBus.Properties",
                    member: "PropertiesChanged",
                },
                |_| true,
            )
            .await
        }
    }
}

/// Listens for changes to the primary egress path (the interface NM considers
/// the default route).
///
/// Notifies when `PrimaryConnection` changes, meaning the interface used for
/// egress traffic has switched. Toggling an ethernet adapter while Wi-Fi is
/// still up will not trigger a notification unless ethernet was the primary
/// connection, which is exactly what we care about for session resets.
pub async fn new_network_notifier(
    _tokio_handle: tokio::runtime::Handle,
    _method: DnsControlMethod,
) -> Result<Worker> {
    Worker::new_dbus(
        SignalParams {
            dest: "org.freedesktop.NetworkManager",
            path: "/org/freedesktop/NetworkManager",
            // Despite what the payload's first argument says, NM stamps
            // org.freedesktop.DBus.Properties in the message header, as
            // confirmed by bus monitoring. The match rule must use that.
            interface: "org.freedesktop.DBus.Properties",
            member: "PropertiesChanged",
        },
        primary_connection_changed,
    )
    .await
}

/// Returns `true` if the `PropertiesChanged` signal body contains a change to
/// `PrimaryConnection`, meaning the default-route interface has switched.
fn primary_connection_changed(body: &zbus::message::Body) -> bool {
    // NM emits one PropertiesChanged per property, with body
    // (interface_name, changed_properties, invalidated_properties).
    type Payload = (
        String,
        HashMap<String, zbus::zvariant::OwnedValue>,
        Vec<String>,
    );
    let Ok((_iface, changed, invalidated)) = body.deserialize::<Payload>() else {
        return false;
    };
    changed.contains_key("PrimaryConnection")
        || invalidated.iter().any(|k| k == "PrimaryConnection")
}

pub struct Worker {
    just_started: bool,
    inner: Inner,
}

enum Inner {
    DBus(Pin<Box<dyn futures::Stream<Item = ()> + Send>>),
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

    async fn new_dbus(
        params: SignalParams,
        filter: fn(&zbus::message::Body) -> bool,
    ) -> Result<Self> {
        let SignalParams {
            dest,
            path,
            interface,
            member,
        } = params;

        let cxn = zbus::Connection::system().await?;
        let proxy = zbus::Proxy::new_owned(cxn, dest, path, interface).await?;
        let stream = proxy
            .receive_signal(member)
            .await?
            .filter(move |msg| std::future::ready(filter(&msg.body())))
            .map(|_| ());
        Ok(Self {
            just_started: true,
            inner: Inner::DBus(Box::pin(stream)),
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
