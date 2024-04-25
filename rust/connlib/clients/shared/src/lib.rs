//! Main connlib library for clients.
pub use connlib_shared::messages::client::ResourceDescription;
pub use connlib_shared::{
    keypair, Callbacks, Cidrv4, Cidrv6, Error, LoginUrl, LoginUrlError, StaticSecret,
};
pub use firezone_tunnel::Sockets;
pub use tracing_appender::non_blocking::WorkerGuard;

use backoff::ExponentialBackoffBuilder;
use connlib_shared::get_user_agent;
use firezone_tunnel::ClientTunnel;
use phoenix_channel::PhoenixChannel;
use std::net::IpAddr;
use std::time::Duration;
use tokio::sync::mpsc::UnboundedReceiver;

mod eventloop;
pub mod file_logger;
mod messages;

const PHOENIX_TOPIC: &str = "client";

use eventloop::Command;
pub use eventloop::Eventloop;
use secrecy::Secret;
use tokio::task::JoinHandle;

/// A session is the entry-point for connlib, maintains the runtime and the tunnel.
///
/// A session is created using [Session::connect], then to stop a session we use [Session::disconnect].
pub struct Session {
    channel: tokio::sync::mpsc::UnboundedSender<Command>,
}

impl Session {
    /// Creates a new [`Session`].
    ///
    /// This connects to the portal a specified using [`LoginUrl`] and creates a wireguard tunnel using the provided private key.
    pub fn connect<CB: Callbacks + 'static>(
        url: LoginUrl,
        sockets: Sockets,
        private_key: StaticSecret,
        os_version_override: Option<String>,
        callbacks: CB,
        max_partition_time: Option<Duration>,
        handle: tokio::runtime::Handle,
    ) -> Self {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();

        let connect_handle = handle.spawn(connect(
            url,
            sockets,
            private_key,
            os_version_override,
            callbacks.clone(),
            max_partition_time,
            rx,
        ));
        handle.spawn(connect_supervisor(connect_handle, callbacks));

        Self { channel: tx }
    }

    /// Attempts to reconnect a [`Session`].
    ///
    /// Reconnecting a session will:
    ///
    /// - Close and re-open a connection to the portal.
    /// - Refresh all allocations
    /// - Rebind local UDP sockets
    ///
    /// # Implementation note
    ///
    /// The reason we rebind the UDP sockets are:
    ///
    /// 1. On MacOS, as socket bound to the unspecified IP cannot send to interfaces attached after the socket has been created.
    /// 2. Switching between networks changes the 3-tuple of the client.
    ///    The TURN protocol identifies a client's allocation based on the 3-tuple.
    ///    Consequently, an allocation is invalid after switching networks and we clear the state.
    ///    Changing the IP would be enough for that.
    ///    However, if the user would now change _back_ to the previous network,
    ///    the TURN server would recognise the old allocation but the client already lost all its state associated with it.
    ///    To avoid race-conditions like this, we rebind the sockets to a new port.
    pub fn reconnect(&self) {
        let _ = self.channel.send(Command::Reconnect);
    }

    /// Sets a new set of upstream DNS servers for this [`Session`].
    ///
    /// Changing the DNS servers clears all cached DNS requests which may be disruptive to the UX.
    /// Clients should only call this when relevant.
    ///
    /// The implementation is idempotent; calling it with the same set of servers is safe.
    pub fn set_dns(&self, new_dns: Vec<IpAddr>) {
        let _ = self.channel.send(Command::SetDns(new_dns));
    }

    /// Disconnect a [`Session`].
    ///
    /// This consumes [`Session`] which cleans up all state associated with it.
    pub fn disconnect(self) {
        let _ = self.channel.send(Command::Stop);
    }
}

/// Connects to the portal and starts a tunnel.
///
/// When this function exits, the tunnel failed unrecoverably and you need to call it again.
async fn connect<CB>(
    url: LoginUrl,
    sockets: Sockets,
    private_key: StaticSecret,
    os_version_override: Option<String>,
    callbacks: CB,
    max_partition_time: Option<Duration>,
    rx: UnboundedReceiver<Command>,
) -> Result<(), Error>
where
    CB: Callbacks + 'static,
{
    let tunnel = ClientTunnel::new(private_key, sockets, callbacks.clone())?;

    let portal = PhoenixChannel::connect(
        Secret::new(url),
        get_user_agent(os_version_override),
        PHOENIX_TOPIC,
        (),
        ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(max_partition_time)
            .build(),
    );

    let mut eventloop = Eventloop::new(tunnel, portal, rx);

    std::future::poll_fn(|cx| eventloop.poll(cx))
        .await
        .map_err(Error::PortalConnectionFailed)?;

    Ok(())
}

/// A supervisor task that handles, when [`connect`] exits.
async fn connect_supervisor<CB>(connect_handle: JoinHandle<Result<(), Error>>, callbacks: CB)
where
    CB: Callbacks,
{
    match connect_handle.await {
        Ok(Ok(())) => {
            tracing::info!("connlib exited gracefully");
        }
        Ok(Err(e)) => {
            tracing::error!("connlib failed: {e}");
            callbacks.on_disconnect(&e);
        }
        Err(e) => match e.try_into_panic() {
            Ok(panic) => {
                if let Some(msg) = panic.downcast_ref::<&str>() {
                    callbacks.on_disconnect(&Error::Panic(msg.to_string()));
                    return;
                }
                if let Some(msg) = panic.downcast_ref::<String>() {
                    callbacks.on_disconnect(&Error::Panic(msg.to_string()));
                    return;
                }

                callbacks.on_disconnect(&Error::PanicNonStringPayload);
            }
            Err(_) => {
                tracing::error!("connlib task was cancelled");
                callbacks.on_disconnect(&Error::Cancelled);
            }
        },
    }
}

#[cfg(test)]
mod tests {
    #[derive(Clone, Default)]
    struct Callbacks {}
    impl connlib_shared::Callbacks for Callbacks {}

    #[cfg(target_os = "linux")]
    #[tokio::test]
    #[ignore = "Performs system-wide I/O, needs sudo"]
    async fn device_linux() {
        device_common().await;
    }

    #[cfg(target_os = "windows")]
    #[tokio::test]
    #[ignore = "Performs system-wide I/O, needs sudo"]
    async fn device_windows() {
        // Install wintun so the test can run
        // CI only needs x86_64 for now
        let wintun_bytes = include_bytes!("../../../../gui-client/wintun/bin/amd64/wintun.dll");
        let wintun_path = connlib_shared::windows::wintun_dll_path().unwrap();
        tokio::fs::create_dir_all(wintun_path.parent().unwrap())
            .await
            .unwrap();
        tokio::fs::write(&wintun_path, wintun_bytes).await.unwrap();

        device_common().await;
    }

    #[cfg(any(target_os = "windows", target_os = "linux"))]
    async fn device_common() {
        let (private_key, _public_key) = connlib_shared::keypair();
        let sockets = crate::Sockets::new();
        let callbacks = Callbacks::default();
        let mut tunnel =
            firezone_tunnel::ClientTunnel::new(private_key, sockets, callbacks).unwrap();
        let upstream_dns = vec![([192, 168, 1, 1], 53).into()];
        let interface = connlib_shared::messages::Interface {
            ipv4: [100, 71, 96, 96].into(),
            ipv6: [0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0019, 0x6538].into(),
            upstream_dns,
        };
        tunnel.set_new_interface_config(interface).unwrap();
        let resources = vec![];
        tunnel.add_resources(&resources).unwrap();

        let tunnel = tokio::spawn(async move {
            std::future::poll_fn(|cx| tunnel.poll_next_event(cx))
                .await
                .unwrap()
        });

        tokio::time::sleep(std::time::Duration::from_secs(5)).await;

        if tunnel.is_finished() {
            tunnel.await.unwrap();
        }
    }
}
