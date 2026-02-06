#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Main connlib library for clients.
pub use connlib_model::StaticSecret;
pub use eventloop::DisconnectError;
pub use tunnel::TunConfig;
use tunnel::messages::client::EgressMessages;
pub use tunnel::messages::client::{IngressMessages, ResourceDescription};

use anyhow::Result;
use connlib_model::{ResourceId, ResourceView};
use eventloop::{Command, Eventloop};
use futures::future::Fuse;
use futures::{FutureExt, StreamExt};
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::collections::HashSet;
use std::future;
use std::net::IpAddr;
use std::sync::Arc;
use std::task::{Context, Poll};
use tokio::sync::mpsc;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio_stream::wrappers::WatchStream;
use tun::Tun;

use crate::eventloop::UserNotification;

mod eventloop;

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
    eventloop: Fuse<JoinHandle<Result<(), DisconnectError>>>,
    resource_list_receiver: WatchStream<Vec<ResourceView>>,
    tun_config_receiver: WatchStream<Option<TunConfig>>,
    user_notification_receiver: mpsc::Receiver<UserNotification>,

    seen_notifications: HashSet<UserNotification>,
}

/// Events the Client application should use to update the state of the operating system / app.
#[derive(Debug)]
pub enum Event {
    /// The TUN device configuration has been updated.
    TunInterfaceUpdated(TunConfig),
    /// The resource list has been updated.
    ResourcesUpdated(Vec<ResourceView>),
    /// Establishing a tunnel for a resource failed because all Gateways are offline in the corresponding site.
    AllGatewaysOffline { resource_id: ResourceId },
    /// Establishing a tunnel for a resource failed because there are no version-compatible Gateways in the corresponding site.
    GatewayVersionMismatch { resource_id: ResourceId },
    /// Connlib has been permanently disconnected from the portal and the tunnel has been shut down.
    Disconnected(DisconnectError),
}

impl Session {
    pub fn connect(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
        is_internet_resource_active: bool,
        dns_servers: Vec<IpAddr>,
        handle: tokio::runtime::Handle,
    ) -> (Self, EventStream) {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let event_stream = EventStream::new(
            |resource_list_sender, tun_config_sender, user_notification_sender| {
                Eventloop::new(
                    tcp_socket_factory,
                    udp_socket_factory,
                    is_internet_resource_active,
                    dns_servers,
                    portal,
                    cmd_rx,
                    resource_list_sender,
                    tun_config_sender,
                    user_notification_sender,
                )
                .run()
            },
            handle,
        );

        (Self { channel: cmd_tx }, event_stream)
    }

    /// Reset a [`Session`].
    ///
    /// Resetting a session will:
    ///
    /// - Close and re-open a connection to the portal.
    /// - Delete all allocations.
    /// - Rebind local UDP sockets.
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

    pub fn set_internet_resource_state(&self, active: bool) {
        let _ = self.channel.send(Command::SetInternetResourceState(active));
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
        loop {
            if let Poll::Ready(Some(resources)) = self.resource_list_receiver.poll_next_unpin(cx) {
                return Poll::Ready(Some(Event::ResourcesUpdated(resources)));
            }

            if let Poll::Ready(Some(Some(config))) = self.tun_config_receiver.poll_next_unpin(cx) {
                return Poll::Ready(Some(Event::TunInterfaceUpdated(config)));
            }

            match self.user_notification_receiver.poll_recv(cx) {
                Poll::Ready(Some(event @ UserNotification::AllGatewaysOffline { resource_id })) => {
                    if !self.seen_notifications.insert(event) {
                        continue;
                    }

                    return Poll::Ready(Some(Event::AllGatewaysOffline { resource_id }));
                }
                Poll::Ready(Some(
                    event @ UserNotification::GatewayVersionMismatch { resource_id },
                )) => {
                    if !self.seen_notifications.insert(event) {
                        continue;
                    }

                    return Poll::Ready(Some(Event::GatewayVersionMismatch { resource_id }));
                }
                Poll::Ready(None) | Poll::Pending => {}
            }

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

            return Poll::Pending;
        }
    }

    pub async fn next(&mut self) -> Option<Event> {
        future::poll_fn(|cx| self.poll_next(cx)).await
    }

    pub async fn drain(&mut self) -> Vec<Event> {
        futures::stream::poll_fn(|cx| self.poll_next(cx))
            .collect()
            .await
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        tracing::debug!("`Session` dropped")
    }
}

impl EventStream {
    fn new<E>(
        make_event_loop: impl FnOnce(
            watch::Sender<Vec<ResourceView>>,
            watch::Sender<Option<TunConfig>>,
            mpsc::Sender<UserNotification>,
        ) -> E,
        handle: tokio::runtime::Handle,
    ) -> Self
    where
        E: Future<Output = Result<(), DisconnectError>> + Send + 'static,
    {
        let (tun_config_sender, tun_config_receiver) = watch::channel(None);
        let (resource_list_sender, resource_list_receiver) = watch::channel(Vec::default());
        let (user_notification_sender, user_notification_receiver) = mpsc::channel(128);

        let event_loop = make_event_loop(
            resource_list_sender,
            tun_config_sender,
            user_notification_sender,
        );

        let eventloop = handle.spawn(event_loop);

        Self {
            eventloop: eventloop.fuse(),
            resource_list_receiver: WatchStream::from_changes(resource_list_receiver),
            tun_config_receiver: WatchStream::from_changes(tun_config_receiver),
            user_notification_receiver,
            seen_notifications: Default::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn event_stream_turn_panic_into_disconnected() {
        let mut stream = EventStream::new(
            |_, _, _| async move { panic!("Boom!") },
            tokio::runtime::Handle::current(),
        );

        let Event::Disconnected(error) = stream.next().await.unwrap() else {
            panic!("Unexpected event!");
        };

        assert!(error.to_string().contains("Boom!"));
    }

    #[tokio::test]
    async fn repeated_polls_dont_panic() {
        let mut stream = EventStream::new(
            |_, _, _| async move { panic!("Boom!") },
            tokio::runtime::Handle::current(),
        );

        let _next = stream.next().await.unwrap();
        let poll = stream.poll_next(&mut Context::from_waker(futures::task::noop_waker_ref()));

        assert!(poll.is_pending());
    }

    #[tokio::test]
    async fn deduplicates_offline_notifications() {
        let mut stream = EventStream::new(
            |_, _, sender| async move {
                sender
                    .send(UserNotification::AllGatewaysOffline {
                        resource_id: ResourceId::from_u128(1),
                    })
                    .await
                    .unwrap();
                sender
                    .send(UserNotification::AllGatewaysOffline {
                        resource_id: ResourceId::from_u128(1),
                    })
                    .await
                    .unwrap();

                Ok(())
            },
            tokio::runtime::Handle::current(),
        );

        let Event::AllGatewaysOffline { resource_id } = stream.next().await.unwrap() else {
            panic!("Unexpected event")
        };

        assert_eq!(resource_id, ResourceId::from_u128(1));
        assert!(
            stream.next().await.is_none(),
            "stream should be closed if event-loop returns"
        );
    }

    #[tokio::test]
    async fn deduplicates_version_mismatch_notifications() {
        let mut stream = EventStream::new(
            |_, _, sender| async move {
                sender
                    .send(UserNotification::GatewayVersionMismatch {
                        resource_id: ResourceId::from_u128(1),
                    })
                    .await
                    .unwrap();
                sender
                    .send(UserNotification::GatewayVersionMismatch {
                        resource_id: ResourceId::from_u128(1),
                    })
                    .await
                    .unwrap();

                Ok(())
            },
            tokio::runtime::Handle::current(),
        );

        let Event::GatewayVersionMismatch { resource_id } = stream.next().await.unwrap() else {
            panic!("Unexpected event")
        };

        assert_eq!(resource_id, ResourceId::from_u128(1));
        assert!(
            stream.next().await.is_none(),
            "stream should be closed if event-loop returns"
        );
    }
}
