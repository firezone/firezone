use anyhow::Result;
use futures::Stream;

/// Subscribes to a DBus signal on the system bus.
pub(crate) async fn signal_stream(
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
