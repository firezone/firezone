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
use futures::StreamExt;
use futures::future::{MaybeDone, maybe_done};
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use serde::{Deserialize, Serialize};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::collections::HashSet;
use std::future;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, UdpSocket as StdUdpSocket};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use tokio::sync::mpsc;
use tokio::sync::watch;
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
    eventloop: MaybeDone<async_runtime::ThreadOutput<Result<(), DisconnectError>>>,
    resource_list_receiver: WatchStream<Vec<ResourceView>>,
    tun_config_receiver: WatchStream<Option<TunConfig>>,
    connected_as_receiver: WatchStream<Option<ConnectedAs>>,
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
    /// Connlib connected to the portal, which named the account and actor this session belongs to.
    ConnectedToPortal(ConnectedAs),
    /// Establishing a tunnel for a resource failed because all Gateways are offline in the corresponding site.
    AllGatewaysOffline { resource_id: ResourceId },
    /// Establishing a tunnel for a resource failed because there are no version-compatible Gateways in the corresponding site.
    GatewayVersionMismatch { resource_id: ResourceId },
    /// Connlib has been permanently disconnected from the portal and the tunnel has been shut down.
    Disconnected(DisconnectError),
}

/// Who the portal says this session belongs to.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ConnectedAs {
    pub account_slug: String,
    pub actor_name: String,
}

impl Session {
    pub fn connect(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
        config: SessionConfig,
    ) -> io::Result<(Self, EventStream)> {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let event_stream = EventStream::new(
            move |resource_list_sender,
                  tun_config_sender,
                  connected_as_sender,
                  user_notification_sender| async move {
                Eventloop::new(
                    tcp_socket_factory,
                    udp_socket_factory,
                    config,
                    portal,
                    cmd_rx,
                    resource_list_sender,
                    tun_config_sender,
                    connected_as_sender,
                    user_notification_sender,
                )?
                .run()
                .await
            },
        )?;

        Ok((Self { channel: cmd_tx }, event_stream))
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

    pub fn set_additional_host_candidates(&self, ips: Vec<IpAddr>) {
        let _ = self.channel.send(Command::SetAdditionalHostCandidates(ips));
    }

    /// Sets a new [`Tun`] device handle.
    pub fn set_tun(&self, new_tun: Box<dyn Tun>) {
        let _ = self.channel.send(Command::SetTun(new_tun));
    }

    pub fn stop(&self) {
        let _ = self.channel.send(Command::Stop);
    }

    /// Resolves once the event-loop has finished, including its graceful shutdown.
    pub async fn closed(&self) {
        self.channel.closed().await
    }
}

impl EventStream {
    pub fn poll_next(&mut self, cx: &mut Context) -> Poll<Option<Event>> {
        // Polled before the channels: the event-loop sends its events before it finishes, so
        // once it has finished, the channels already hold all of them.
        if matches!(self.eventloop, MaybeDone::Gone) {
            return Poll::Ready(None);
        }
        let finished = Pin::new(&mut self.eventloop).poll(cx).is_ready();

        loop {
            // Polled first so the account and actor are known before anything else the
            // same `init` produced.
            if let Poll::Ready(Some(Some(connected))) =
                self.connected_as_receiver.poll_next_unpin(cx)
            {
                return Poll::Ready(Some(Event::ConnectedToPortal(connected)));
            }

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

            break;
        }

        if !finished {
            return Poll::Pending;
        }

        match Pin::new(&mut self.eventloop).take_output() {
            Some(Ok(Ok(()))) | None => Poll::Ready(None),
            Some(Ok(Err(e))) => Poll::Ready(Some(Event::Disconnected(e))),
            Some(Err(e)) => Poll::Ready(Some(Event::Disconnected(DisconnectError::from(
                e.context("connlib crashed"),
            )))),
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
            watch::Sender<Option<ConnectedAs>>,
            mpsc::Sender<UserNotification>,
        ) -> E
        + Send
        + 'static,
    ) -> io::Result<Self>
    where
        E: Future<Output = Result<(), DisconnectError>>,
    {
        let (tun_config_sender, tun_config_receiver) = watch::channel(None);
        let (resource_list_sender, resource_list_receiver) = watch::channel(Vec::default());
        let (connected_as_sender, connected_as_receiver) = watch::channel(None);
        let (user_notification_sender, user_notification_receiver) = mpsc::channel(128);

        let eventloop = async_runtime::spawn_thread("fz-eventloop", move || {
            make_event_loop(
                resource_list_sender,
                tun_config_sender,
                connected_as_sender,
                user_notification_sender,
            )
        })?;

        Ok(Self {
            eventloop: maybe_done(eventloop),
            resource_list_receiver: WatchStream::from_changes(resource_list_receiver),
            tun_config_receiver: WatchStream::from_changes(tun_config_receiver),
            connected_as_receiver: WatchStream::from_changes(connected_as_receiver),
            user_notification_receiver,
            seen_notifications: Default::default(),
        })
    }
}

/// The settings a [`Session`] starts with.
#[derive(Default)]
pub struct SessionConfig {
    pub(crate) is_internet_resource_active: bool,
    pub(crate) dns_servers: Vec<IpAddr>,
    pub(crate) additional_host_candidates: Vec<IpAddr>,
    pub(crate) flow_logs_dir: Option<PathBuf>,
    pub(crate) local_flow_logs: bool,
}

impl SessionConfig {
    pub fn with_internet_resource_active(mut self, active: bool) -> Self {
        self.is_internet_resource_active = active;
        self
    }

    pub fn with_dns_servers(mut self, servers: Vec<IpAddr>) -> Self {
        self.dns_servers = servers;
        self
    }

    pub fn with_additional_host_candidates(mut self, ips: Vec<IpAddr>) -> Self {
        self.additional_host_candidates = ips;
        self
    }

    pub fn with_flow_logs_dir(mut self, dir: Option<PathBuf>) -> Self {
        self.flow_logs_dir = dir;
        self
    }

    pub fn with_local_flow_logs(mut self, enabled: bool) -> Self {
        self.local_flow_logs = enabled;
        self
    }
}

/// Finds a UDP port that is free on both IP stacks.
pub(crate) fn free_udp_port() -> io::Result<u16> {
    const ATTEMPTS: usize = 5;

    for _ in 0..ATTEMPTS {
        let port = StdUdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?
            .local_addr()?
            .port();

        match StdUdpSocket::bind((Ipv6Addr::UNSPECIFIED, port)) {
            Err(e) if e.kind() == io::ErrorKind::AddrInUse => continue,
            // Anything else means there is no IPv6 stack to collide on.
            Ok(_) | Err(_) => return Ok(port),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AddrInUse,
        "Failed to find a UDP port that is free for IPv4 and IPv6",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn event_stream_turn_panic_into_disconnected() {
        let mut stream = EventStream::new(|_, _, _, _| async move { panic!("Boom!") }).unwrap();

        let Event::Disconnected(error) = stream.next().await.unwrap() else {
            panic!("Unexpected event!");
        };

        assert!(error.to_string().contains("Boom!"));
    }

    #[tokio::test]
    async fn repeated_polls_dont_panic() {
        let mut stream = EventStream::new(|_, _, _, _| async move { panic!("Boom!") }).unwrap();

        let _next = stream.next().await.unwrap();
        let poll = stream.poll_next(&mut Context::from_waker(futures::task::noop_waker_ref()));

        assert!(matches!(poll, Poll::Ready(None)));
    }

    #[tokio::test]
    async fn stream_ends_after_disconnect() {
        let mut stream = EventStream::new(|_, _, _, _| async move {
            Err(DisconnectError::from(anyhow::anyhow!("Boom!")))
        })
        .unwrap();

        let Event::Disconnected(_) = stream.next().await.unwrap() else {
            panic!("Unexpected event!");
        };

        assert!(
            stream.next().await.is_none(),
            "stream should be closed once the event-loop has disconnected"
        );
    }

    #[tokio::test]
    async fn connected_to_portal_precedes_resources_from_the_same_init() {
        let mut stream = EventStream::new(|resource_list, _, connected_as, _| async move {
            connected_as
                .send(Some(ConnectedAs {
                    account_slug: "acme".to_owned(),
                    actor_name: "Jane Doe".to_owned(),
                }))
                .unwrap();
            resource_list.send(Vec::default()).unwrap();

            Ok(())
        })
        .unwrap();

        let Event::ConnectedToPortal(connected) = stream.next().await.unwrap() else {
            panic!("Unexpected event")
        };

        assert_eq!(connected.account_slug, "acme");
        assert_eq!(connected.actor_name, "Jane Doe");
    }

    #[tokio::test]
    async fn deduplicates_offline_notifications() {
        let mut stream = EventStream::new(|_, _, _, sender| async move {
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
        })
        .unwrap();

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
        let mut stream = EventStream::new(|_, _, _, sender| async move {
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
        })
        .unwrap();

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
