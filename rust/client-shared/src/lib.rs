//! Main connlib library for clients.
pub use crate::serde_routelist::{V4RouteList, V6RouteList};
pub use connlib_model::StaticSecret;
pub use eventloop::{DisconnectError, Event};
pub use firezone_tunnel::TunConfig;
pub use firezone_tunnel::messages::client::{IngressMessages, ResourceDescription};

use anyhow::{Context as _, Result};
use connlib_model::ResourceId;
use eventloop::{Command, Eventloop};
use firezone_tunnel::ClientTunnel;
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::collections::BTreeSet;
use std::net::IpAddr;
use std::sync::Arc;
use std::task::{Context, Poll};
use tokio::sync::mpsc::{Receiver, UnboundedSender};
use tokio::task::JoinHandle;
use tun::Tun;

mod eventloop;
mod serde_routelist;

const PHOENIX_TOPIC: &str = "client";

/// A session is the entry-point for connlib, maintains the runtime and the tunnel.
///
/// A session is created using [`Session::connect`].
/// To stop the session, simply drop this struct.
#[derive(Clone, Debug)]
pub struct Session {
    channel: UnboundedSender<Command>,
}

#[derive(Debug)]
pub struct EventStream {
    channel: Receiver<Event>,
}

impl Session {
    /// Creates a new [`Session`].
    ///
    /// This connects to the portal using the given [`LoginUrl`](phoenix_channel::LoginUrl) and creates a wireguard tunnel using the provided private key.
    pub fn connect(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
        handle: tokio::runtime::Handle,
    ) -> (Self, EventStream) {
        let (cmd_tx, cmd_rx) = tokio::sync::mpsc::unbounded_channel();
        let (event_tx, event_rx) = tokio::sync::mpsc::channel(1000);

        let eventloop_handle = handle.spawn(
            Eventloop::new(
                ClientTunnel::new(tcp_socket_factory, udp_socket_factory),
                portal,
                cmd_rx,
                event_tx.clone(),
            )
            .run(),
        );
        handle.spawn(connect_supervisor(eventloop_handle, event_tx));

        (Self { channel: cmd_tx }, EventStream { channel: event_rx })
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
    pub fn reset(&self, reason: String) {
        let _ = self.channel.send(Command::Reset(reason));
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

    pub fn stop(&self) {
        let _ = self.channel.send(Command::Stop);
    }
}

impl EventStream {
    pub fn poll_next(&mut self, cx: &mut Context) -> Poll<Option<Event>> {
        self.channel.poll_recv(cx)
    }

    pub async fn next(&mut self) -> Option<Event> {
        self.channel.recv().await
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        tracing::debug!("`Session` dropped")
    }
}

/// A supervisor task that handles, when [`connect`] exits.
async fn connect_supervisor(
    connect_handle: JoinHandle<Result<(), DisconnectError>>,
    event_tx: tokio::sync::mpsc::Sender<Event>,
) {
    let task = async {
        connect_handle.await.context("connlib crashed")??;

        Ok(())
    };

    let error = match task.await {
        Ok(()) => {
            tracing::info!("connlib exited gracefully");

            return;
        }
        Err(e) => e,
    };

    match event_tx.send(Event::Disconnected(error)).await {
        Ok(()) => (),
        Err(_) => tracing::debug!("Event stream closed before we could send disconnected event"),
    }
}
