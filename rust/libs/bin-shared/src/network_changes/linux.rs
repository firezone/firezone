//! Network change detection for Linux via DBus / NetworkManager

use crate::DnsControlMethod;
use anyhow::Result;
use futures::stream::BoxStream;
use futures::{Stream, StreamExt as _, stream};
use std::{collections::HashMap, pin::Pin, time::Duration};
use tokio::time::MissedTickBehavior;

/// Listens for changes of system-wide DNS resolvers
///
/// e.g. if you run `sudo resolvectl dns eno1 1.1.1.1` this should
/// notify.
///
/// Should be equivalent to `dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',path='/org/freedesktop/resolve1',member='PropertiesChanged'"`
pub async fn new_dns_notifier(
    _tokio_handle: tokio::runtime::Handle,
    method: DnsControlMethod,
) -> Result<impl Stream<Item = Result<()>> + Unpin> {
    let stream = match method {
        DnsControlMethod::Disabled | DnsControlMethod::EtcResolvConf => {
            interval_stream(Duration::from_secs(5))
                .inspect(|_| tracing::debug!("DNS change poller ticked"))
                .map(|_| Ok(()))
                .boxed()
        }
        DnsControlMethod::SystemdResolved => dbus_stream(
            "org.freedesktop.resolve1",
            "/org/freedesktop/resolve1",
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
        )
        .await?
        .inspect(|_| tracing::debug!("Received DBus notification for DNS server change"))
        .map(|_| Ok(()))
        .chain(stream::pending()) // Ensure this never ends.
        .boxed(),
    };

    Ok(stream::empty()
        // Yield once immediately so callers are notified of the current
        // DNS state on startup without waiting for the first real change.
        .chain(stream::once(async { Ok(()) }))
        // Then yield on every subsequent change.
        .chain(stream)
        .boxed())
}

/// Listens for changes to the primary egress path (the interface NM considers
/// the default route).
///
/// Notifies when `PrimaryConnection` changes, meaning the interface used for
/// egress traffic has switched. Toggling an ethernet adapter while Wi-Fi is
/// still up will not trigger a notification unless ethernet was the primary
/// connection, which is exactly what we care about for session resets.
///
/// Returns a [`NetworkNotifier`] which implements [`Default`] as a no-op
/// stream, so callers can use `.unwrap_or_default()` to gracefully handle
/// failure.
pub async fn new_network_notifier() -> Result<impl Stream<Item = Result<()>> + Default + Unpin> {
    let stream = dbus_stream(
        "org.freedesktop.NetworkManager",
        "/org/freedesktop/NetworkManager",
        // Despite what the payload's first argument says, NM stamps
        // org.freedesktop.DBus.Properties in the message header, as
        // confirmed by bus monitoring. The match rule must use that.
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
    )
    .await?
    .filter(|msg| std::future::ready(primary_connection_changed(&msg.body())))
    .inspect(|_| tracing::debug!("Received DBus notification for primary interface change"))
    .chain(stream::pending()); // Ensure this never ends.

    Ok(NetworkNotifier(stream.map(|_| Ok(())).boxed()))
}

/// A stream of network change notifications.
///
/// Implements [`Default`] as a no-op stream so callers can use
/// `.unwrap_or_default()` to gracefully degrade when the notifier fails to
/// initialise.
struct NetworkNotifier(BoxStream<'static, Result<()>>);

impl Default for NetworkNotifier {
    fn default() -> Self {
        NetworkNotifier(Box::pin(stream::pending()))
    }
}

impl Stream for NetworkNotifier {
    type Item = Result<()>;

    fn poll_next(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        self.0.as_mut().poll_next(cx)
    }
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

fn interval_stream(interval: Duration) -> impl Stream<Item = ()> + Unpin {
    let mut interval = tokio::time::interval(interval);
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

    stream::unfold(interval, |mut interval| async move {
        interval.tick().await;
        Some(((), interval))
    })
    .boxed()
}

async fn dbus_stream(
    dest: &'static str,
    path: &'static str,
    interface: &'static str,
    member: &'static str,
) -> Result<impl Stream<Item = zbus::Message> + Unpin> {
    let cxn = zbus::Connection::system().await?;
    let proxy = zbus::Proxy::new_owned(cxn, dest, path, interface).await?;
    let stream = proxy.receive_signal(member).await?;

    Ok(stream)
}
