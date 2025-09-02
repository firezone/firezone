//! Main connlib library for clients.
pub use crate::serde_routelist::{V4RouteList, V6RouteList};
pub use connlib_model::StaticSecret;
pub use eventloop::DisconnectError;
pub use firezone_tunnel::TunConfig;
pub use firezone_tunnel::messages::client::{IngressMessages, ResourceDescription};

use anyhow::Result;
use connlib_model::{ResourceId, ResourceView};
use eventloop::{Command, Eventloop};
use futures::{FutureExt, StreamExt};
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::collections::BTreeSet;
use std::future;
use std::net::IpAddr;
use std::sync::Arc;
use std::task::{Context, Poll};
use tokio::sync::mpsc;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio_stream::wrappers::WatchStream;
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
    channel: mpsc::UnboundedSender<Command>,
}

#[derive(Debug)]
pub struct EventStream {
    eventloop: JoinHandle<Result<(), DisconnectError>>,
    resource_list_receiver: WatchStream<Vec<ResourceView>>,
    tun_config_receiver: WatchStream<Option<TunConfig>>,
}

#[derive(Debug)]
pub enum Event {
    TunInterfaceUpdated(TunConfig),
    ResourcesUpdated(Vec<ResourceView>),
    Disconnected(DisconnectError),
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
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();

        // Use `watch` channels for resource list and TUN config because we are only ever interested in the last value and don't care about intermediate updates.
        let (tun_config_sender, tun_config_receiver) = watch::channel(None);
        let (resource_list_sender, resource_list_receiver) = watch::channel(Vec::default());

        let eventloop = handle.spawn(
            Eventloop::new(
                tcp_socket_factory,
                udp_socket_factory,
                portal,
                cmd_rx,
                resource_list_sender,
                tun_config_sender,
            )
            .run(),
        );

        (
            Self { channel: cmd_tx },
            EventStream {
                eventloop,
                resource_list_receiver: WatchStream::from_changes(resource_list_receiver),
                tun_config_receiver: WatchStream::from_changes(tun_config_receiver),
            },
        )
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
        match self.eventloop.poll_unpin(cx) {
            Poll::Ready(Ok(Ok(()))) => return Poll::Ready(None),
            Poll::Ready(Ok(Err(e))) => return Poll::Ready(Some(Event::Disconnected(e))),
            Poll::Ready(Err(e)) => {
                return Poll::Ready(Some(Event::Disconnected(DisconnectError::from(
                    anyhow::Error::new(e).context("connlib crashed"),
                ))));
            }
            Poll::Pending => {}
        }

        if let Poll::Ready(Some(resources)) = self.resource_list_receiver.poll_next_unpin(cx) {
            return Poll::Ready(Some(Event::ResourcesUpdated(resources)));
        }

        if let Poll::Ready(Some(Some(config))) = self.tun_config_receiver.poll_next_unpin(cx) {
            return Poll::Ready(Some(Event::TunInterfaceUpdated(config)));
        }

        Poll::Pending
    }

    pub async fn next(&mut self) -> Option<Event> {
        future::poll_fn(|cx| self.poll_next(cx)).await
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        tracing::debug!("`Session` dropped")
    }
}
