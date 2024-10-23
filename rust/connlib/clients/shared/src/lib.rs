//! Main connlib library for clients.
pub use crate::serde_routelist::{V4RouteList, V6RouteList};
pub use callbacks::{Callbacks, DisconnectError};
pub use connlib_model::StaticSecret;
pub use eventloop::Eventloop;
pub use firezone_tunnel::messages::client::{
    ResourceDescription, {IngressMessages, ReplyMessages},
};

use connlib_model::ResourceId;
use eventloop::Command;
use firezone_tunnel::ClientTunnel;
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::collections::{BTreeMap, BTreeSet};
use std::net::IpAddr;
use std::sync::Arc;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::task::JoinHandle;
use tun::Tun;

mod callbacks;
mod eventloop;
mod serde_routelist;

const PHOENIX_TOPIC: &str = "client";

/// A session is the entry-point for connlib, maintains the runtime and the tunnel.
///
/// A session is created using [Session::connect], then to stop a session we use [Session::disconnect].
#[derive(Clone)]
pub struct Session {
    channel: tokio::sync::mpsc::UnboundedSender<Command>,
}

impl Session {
    /// Creates a new [`Session`].
    ///
    /// This connects to the portal using the given [`LoginUrl`](phoenix_channel::LoginUrl) and creates a wireguard tunnel using the provided private key.
    pub fn connect<CB: Callbacks + 'static>(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        callbacks: CB,
        portal: PhoenixChannel<(), IngressMessages, ReplyMessages, PublicKeyParam>,
        handle: tokio::runtime::Handle,
    ) -> Self {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();

        let connect_handle = handle.spawn(connect(
            tcp_socket_factory,
            udp_socket_factory,
            callbacks.clone(),
            portal,
            rx,
        ));
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

    pub fn set_disabled_resources(&self, disabled_resources: BTreeSet<ResourceId>) {
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
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    callbacks: CB,
    portal: PhoenixChannel<(), IngressMessages, ReplyMessages, PublicKeyParam>,
    rx: UnboundedReceiver<Command>,
) -> Result<(), phoenix_channel::Error>
where
    CB: Callbacks + 'static,
{
    let tunnel = ClientTunnel::new(
        tcp_socket_factory,
        udp_socket_factory,
        BTreeMap::from([(portal.server_host().to_owned(), portal.resolved_addresses())]),
    );

    let mut eventloop = Eventloop::new(tunnel, callbacks, portal, rx);

    std::future::poll_fn(|cx| eventloop.poll(cx)).await?;

    Ok(())
}

/// A supervisor task that handles, when [`connect`] exits.
async fn connect_supervisor<CB>(
    connect_handle: JoinHandle<Result<(), phoenix_channel::Error>>,
    callbacks: CB,
) where
    CB: Callbacks,
{
    match connect_handle.await {
        Ok(Ok(())) => {
            tracing::info!("connlib exited gracefully");
        }
        Ok(Err(e)) => callbacks.on_disconnect(&DisconnectError::PortalConnectionFailed(e)),
        Err(e) => callbacks.on_disconnect(&DisconnectError::Crash(e)),
    }
}
