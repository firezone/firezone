//! Main connlib library for clients.
pub use crate::serde_routelist::{V4RouteList, V6RouteList};
pub use connlib_shared::messages::client::ResourceDescription;
pub use connlib_shared::{
    callbacks, keypair, Callbacks, Error, LoginUrl, LoginUrlError, StaticSecret,
};
pub use eventloop::Eventloop;
pub use tracing_appender::non_blocking::WorkerGuard;

use connlib_shared::messages::ResourceId;
use eventloop::Command;
use firezone_tunnel::ClientTunnel;
use messages::{IngressMessages, ReplyMessages};
use phoenix_channel::PhoenixChannel;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::sync::Arc;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::task::JoinHandle;
use tun::Tun;

mod eventloop;
pub mod file_logger;
mod messages;
mod serde_routelist;

const PHOENIX_TOPIC: &str = "client";

/// A session is the entry-point for connlib, maintains the runtime and the tunnel.
///
/// A session is created using [Session::connect], then to stop a session we use [Session::disconnect].
#[derive(Clone)]
pub struct Session {
    channel: tokio::sync::mpsc::UnboundedSender<Command>,
}

/// Arguments for `connect`, since Clippy said 8 args is too many
pub struct ConnectArgs<CB> {
    pub tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    pub udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    pub private_key: StaticSecret,
    pub callbacks: CB,
}

impl Session {
    /// Creates a new [`Session`].
    ///
    /// This connects to the portal a specified using [`LoginUrl`] and creates a wireguard tunnel using the provided private key.
    pub fn connect<CB: Callbacks + 'static>(
        args: ConnectArgs<CB>,
        portal: PhoenixChannel<(), IngressMessages, ReplyMessages>,
        handle: tokio::runtime::Handle,
    ) -> Self {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();

        let callbacks = args.callbacks.clone();
        let connect_handle = handle.spawn(connect(args, portal, rx));
        handle.spawn(connect_supervisor(connect_handle, callbacks));

        Self { channel: tx }
    }

    /// Reset a [`Session`].
    ///
    /// Resetting a session will:
    ///
    /// - Close and re-open a connection to the portal.
    /// - Delete all allocations.
    /// - Rebind local UDP sockets.
    ///
    /// # Implementation note
    ///
    /// The reason we rebind the UDP sockets are:
    ///
    /// 1. On MacOS, a socket bound to the unspecified IP cannot send to interfaces attached after the socket has been created.
    /// 2. Switching between networks changes the 3-tuple of the client.
    ///    The TURN protocol identifies a client's allocation based on the 3-tuple.
    ///    Consequently, an allocation is invalid after switching networks and we clear the state.
    ///    Changing the IP would be enough for that.
    ///    However, if the user would now change _back_ to the previous network,
    ///    the TURN server would recognise the old allocation but the client already lost all its state associated with it.
    ///    To avoid race-conditions like this, we rebind the sockets to a new port.
    pub fn reset(&self) {
        let _ = self.channel.send(Command::Reset);
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

    pub fn set_disabled_resources(&self, disabled_resources: HashSet<ResourceId>) {
        let _ = self
            .channel
            .send(Command::SetDisabledResources(disabled_resources));
    }

    /// Sets a new [`Tun`] device handle.
    pub fn set_tun(&self, new_tun: Box<dyn Tun>) {
        let _ = self.channel.send(Command::SetTun(new_tun));
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
    args: ConnectArgs<CB>,
    portal: PhoenixChannel<(), IngressMessages, ReplyMessages>,
    rx: UnboundedReceiver<Command>,
) -> Result<(), Error>
where
    CB: Callbacks + 'static,
{
    let ConnectArgs {
        private_key,
        callbacks,
        udp_socket_factory,
        tcp_socket_factory,
    } = args;

    let tunnel = ClientTunnel::new(
        private_key,
        tcp_socket_factory,
        udp_socket_factory,
        HashMap::from([(portal.server_host().to_owned(), portal.resolved_addresses())]),
    )?;

    let mut eventloop = Eventloop::new(tunnel, callbacks, portal, rx);

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
                    tracing::error!("connlib panicked: {msg}");
                    callbacks.on_disconnect(&Error::Panic(msg.to_string()));
                    return;
                }
                if let Some(msg) = panic.downcast_ref::<String>() {
                    tracing::error!("connlib panicked: {msg}");
                    callbacks.on_disconnect(&Error::Panic(msg.to_string()));
                    return;
                }

                tracing::error!("connlib panicked with a non-string payload");
                callbacks.on_disconnect(&Error::PanicNonStringPayload);
            }
            Err(_) => {
                tracing::error!("connlib task was cancelled");
                callbacks.on_disconnect(&Error::Cancelled);
            }
        },
    }
}
