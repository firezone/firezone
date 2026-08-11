use anyhow::{Context as _, Result};
use futures::StreamExt as _;
use std::collections::HashMap;
use url::Url;

pub(crate) async fn show(
    app_id: &str,
    title: &str,
    body: &str,
    _open_url: Option<&Url>, // TODO: Clickable notifications are not implemented on Linux.
) -> Result<()> {
    let connection = zbus::Connection::session()
        .await
        .context("Failed to connect to session bus")?;

    show_at(&connection, app_id, title, body).await?;

    Ok(())
}

/// Shows a notification via the [`org.freedesktop.Notifications`] D-Bus interface.
///
/// Resolves once the notification is closed: the D-Bus connection must stay
/// open for as long as the notification is showing, otherwise it doesn't get
/// displayed reliably on all desktops.
///
/// [`org.freedesktop.Notifications`]: https://specifications.freedesktop.org/notification-spec/latest/protocol.html
async fn show_at(
    connection: &zbus::Connection,
    app_name: &str,
    summary: &str,
    body: &str,
) -> Result<()> {
    let proxy = zbus::Proxy::new(
        connection,
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
    )
    .await
    .context("Failed to create proxy")?;

    // Subscribe before `Notify` so we cannot miss the close signal.
    let mut closed = proxy
        .receive_signal("NotificationClosed")
        .await
        .context("Failed to subscribe to `NotificationClosed`")?;

    let id: u32 = proxy
        .call(
            "Notify",
            &(
                app_name,
                0_u32, // We are not replacing an existing notification.
                "",    // No icon.
                summary,
                body,
                Vec::<&str>::new(),                            // No actions.
                HashMap::<&str, zbus::zvariant::Value>::new(), // No hints.
                -1_i32, // Let the server pick an expiry timeout.
            ),
        )
        .await
        .context("Failed to call `Notify`")?;

    while let Some(message) = closed.next().await {
        let (closed_id, _reason): (u32, u32) = message
            .body()
            .deserialize()
            .context("Failed to deserialize `NotificationClosed`")?;

        if closed_id == id {
            break;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead as _;
    use std::time::Duration;

    const NOTIFICATION_ID: u32 = 42;

    #[tokio::test]
    async fn shows_notification_end_to_end() {
        let daemon = DbusDaemon::start();

        let (received_tx, mut received_rx) = futures::channel::mpsc::unbounded();
        let server = zbus::connection::Builder::address(daemon.address.as_str())
            .unwrap()
            .name("org.freedesktop.Notifications")
            .unwrap()
            .serve_at(
                "/org/freedesktop/Notifications",
                MockNotifications { received_tx },
            )
            .unwrap()
            .build()
            .await
            .unwrap();
        let client = zbus::connection::Builder::address(daemon.address.as_str())
            .unwrap()
            .build()
            .await
            .unwrap();

        let task =
            tokio::spawn(
                async move { show_at(&client, "Firezone", "Test title", "Test body").await },
            );

        // The daemon must receive exactly what we sent.
        let notify = tokio::time::timeout(Duration::from_secs(10), received_rx.next())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(notify.app_name, "Firezone");
        assert_eq!(notify.replaces_id, 0);
        assert_eq!(notify.app_icon, "");
        assert_eq!(notify.summary, "Test title");
        assert_eq!(notify.body, "Test body");
        assert!(notify.actions.is_empty());
        assert_eq!(notify.num_hints, 0);
        assert_eq!(notify.expire_timeout, -1);

        // Closing some other notification must not resolve ours.
        emit_notification_closed(&server, NOTIFICATION_ID + 1).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!task.is_finished());

        // Closing ours must.
        emit_notification_closed(&server, NOTIFICATION_ID).await;
        tokio::time::timeout(Duration::from_secs(10), task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }

    async fn emit_notification_closed(connection: &zbus::Connection, id: u32) {
        connection
            .emit_signal(
                None::<zbus::names::BusName>,
                "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications",
                "NotificationClosed",
                &(id, 1_u32),
            )
            .await
            .unwrap();
    }

    struct MockNotifications {
        received_tx: futures::channel::mpsc::UnboundedSender<ReceivedNotify>,
    }

    #[zbus::interface(name = "org.freedesktop.Notifications")]
    impl MockNotifications {
        fn notify(
            &self,
            app_name: String,
            replaces_id: u32,
            app_icon: String,
            summary: String,
            body: String,
            actions: Vec<String>,
            hints: HashMap<String, zbus::zvariant::OwnedValue>,
            expire_timeout: i32,
        ) -> u32 {
            self.received_tx
                .unbounded_send(ReceivedNotify {
                    app_name,
                    replaces_id,
                    app_icon,
                    summary,
                    body,
                    actions,
                    num_hints: hints.len(),
                    expire_timeout,
                })
                .unwrap();

            NOTIFICATION_ID
        }
    }

    #[derive(Debug)]
    struct ReceivedNotify {
        app_name: String,
        replaces_id: u32,
        app_icon: String,
        summary: String,
        body: String,
        actions: Vec<String>,
        num_hints: usize,
        expire_timeout: i32,
    }

    /// A private session bus, killed on drop.
    struct DbusDaemon {
        process: std::process::Child,
        address: String,
    }

    impl DbusDaemon {
        fn start() -> Self {
            let mut process = std::process::Command::new("dbus-daemon")
                .args(["--session", "--nofork", "--print-address"])
                .stdout(std::process::Stdio::piped())
                .spawn()
                .expect("`dbus-daemon` must be installed to run this test");

            let stdout = process.stdout.take().unwrap();
            let mut address = String::new();
            std::io::BufReader::new(stdout)
                .read_line(&mut address)
                .unwrap();

            Self {
                process,
                address: address.trim().to_owned(),
            }
        }
    }

    impl Drop for DbusDaemon {
        fn drop(&mut self) {
            let _ = self.process.kill();
            let _ = self.process.wait();
        }
    }
}
