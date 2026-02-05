use crate::PHOENIX_TOPIC;
use anyhow::{Context as _, ErrorExt as _, Result};
use connlib_model::{ClientOrGatewayId, PublicKey, ResourceId, ResourceView};
use l4_udp_dns_client::UdpDnsClient;
use parking_lot::Mutex;
use phoenix_channel::{ErrorReply, PhoenixChannel, PublicKeyParam};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::ops::ControlFlow;
use std::pin::pin;
use std::sync::Arc;
use std::time::Instant;
use std::{
    collections::BTreeSet,
    io,
    net::IpAddr,
    task::{Context, Poll},
};
use std::{future, mem};
use tokio::sync::{mpsc, watch};
use tun::Tun;
use tunnel::messages::RelaysPresence;
use tunnel::messages::client::{
    ClientIceCandidates, EgressMessages, FailReason, FlowCreated, FlowCreationFailed,
    GatewayIceCandidates, IngressMessages, InitClient,
};
use tunnel::{ClientEvent, ClientTunnel, DnsResourceRecord, IpConfig, TunConfig, TunnelError};

/// In-memory cache for DNS resource records.
///
/// This is cached in a `static` to ensure it persists across sessions but gets cleared
/// once the process stops.
///
/// The ideal lifetime of this cache would be that of the current "boot session" of the computer.
/// That would ensure that network connections to IPs handed out by the stub resolver will
/// always point to the same resource.
///
/// On Linux and Windows, the process is a background-service and needs to be explicitly stopped.
/// Therefore, this will most likely outlive any other network connection unless the user messes with it.
///
/// On MacOS, iOS and Android, the OS manages the background-service for us.
/// Thus, while being disconnected, the OS may terminate the process and therefore clear this cache.
/// In most cases, the process will however stay around which makes this solution workable.
///
/// One alternative would be a file-system based cache.
/// That however means we need to define a more explicit eviction policy to stop the cache from growing.
static DNS_RESOURCE_RECORDS_CACHE: Mutex<BTreeSet<DnsResourceRecord>> = Mutex::new(BTreeSet::new());

pub struct Eventloop {
    tunnel: Option<ClientTunnel>,

    cmd_rx: mpsc::UnboundedReceiver<Command>,
    resource_list_sender: watch::Sender<Vec<ResourceView>>,
    tun_config_sender: watch::Sender<Option<TunConfig>>,
    user_notification_sender: mpsc::Sender<UserNotification>,

    portal_event_rx: mpsc::Receiver<Result<IngressMessages, phoenix_channel::Error>>,
    portal_cmd_tx: mpsc::Sender<PortalCommand>,

    logged_permission_denied: bool,
}

/// Commands that can be sent to the [`Eventloop`].
pub enum Command {
    Reset(String),
    Stop,
    SetDns(Vec<IpAddr>),
    SetTun(Box<dyn Tun>),
    SetInternetResourceState(bool),
}

#[derive(Debug, PartialEq, Eq, Hash)]
pub enum UserNotification {
    AllGatewaysOffline { resource_id: ResourceId },
    GatewayVersionMismatch { resource_id: ResourceId },
}

enum PortalCommand {
    Connect(PublicKeyParam),
    Send(EgressMessages),
    UpdateDnsServers(Vec<IpAddr>),
}

/// Unified error type to use across connlib.
#[derive(thiserror::Error, Debug)]
#[error("{0:#}")]
pub struct DisconnectError(anyhow::Error);

impl From<anyhow::Error> for DisconnectError {
    fn from(e: anyhow::Error) -> Self {
        Self(e)
    }
}

impl DisconnectError {
    pub fn is_authentication_error(&self) -> bool {
        let Some(e) = self.0.any_downcast_ref::<phoenix_channel::Error>() else {
            return false;
        };

        e.is_authentication_error()
    }
}

impl Eventloop {
    pub(crate) fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        is_internet_resource_active: bool,
        dns_servers: Vec<IpAddr>,
        portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
        cmd_rx: mpsc::UnboundedReceiver<Command>,
        resource_list_sender: watch::Sender<Vec<ResourceView>>,
        tun_config_sender: watch::Sender<Option<TunConfig>>,
        user_notification_sender: mpsc::Sender<UserNotification>,
    ) -> Self {
        let (portal_event_tx, portal_event_rx) = mpsc::channel(128);
        let (portal_cmd_tx, portal_cmd_rx) = mpsc::channel(128);

        let mut tunnel = ClientTunnel::new(
            tcp_socket_factory,
            udp_socket_factory.clone(),
            DNS_RESOURCE_RECORDS_CACHE.lock().clone(),
            is_internet_resource_active,
        );
        tunnel.update_system_resolvers(dns_servers.clone());

        tokio::spawn(phoenix_channel_event_loop(
            portal,
            PublicKeyParam(tunnel.public_key().to_bytes()),
            portal_event_tx,
            portal_cmd_rx,
            udp_socket_factory.clone(),
            dns_servers,
        ));

        Self {
            tunnel: Some(tunnel),
            cmd_rx,
            logged_permission_denied: false,
            portal_event_rx,
            portal_cmd_tx,
            resource_list_sender,
            tun_config_sender,
            user_notification_sender,
        }
    }
}

enum CombinedEvent {
    Command(Option<Command>),
    Tunnel(ClientEvent),
    Portal(Option<Result<IngressMessages, phoenix_channel::Error>>),
}

impl Eventloop {
    pub async fn run(mut self) -> Result<(), DisconnectError> {
        loop {
            match self.tick().await {
                Ok(ControlFlow::Continue(())) => continue,
                Ok(ControlFlow::Break(())) => {
                    self.shut_down_tunnel().await?;

                    return Ok(());
                }
                Err(e) => {
                    if !e.is_authentication_error() {
                        tracing::error!("Fatal tunnel error: {e:#}");
                    }

                    // Ignore error from shutdown to not obscure the original error.
                    let _ = self.shut_down_tunnel().await;

                    return Err(e);
                }
            }
        }
    }

    async fn tick(&mut self) -> Result<ControlFlow<(), ()>, DisconnectError> {
        match future::poll_fn(|cx| self.next_event(cx)).await {
            CombinedEvent::Command(None) => Ok(ControlFlow::Break(())),
            CombinedEvent::Command(Some(cmd)) => {
                let cf = self.handle_eventloop_command(cmd).await?;

                Ok(cf)
            }
            CombinedEvent::Tunnel(event) => {
                self.handle_tunnel_event(event).await?;

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::Portal(Some(event)) => {
                let msg = event.context("Connection to portal failed")?;
                self.handle_portal_message(msg).await?;

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::Portal(None) => Err(DisconnectError(anyhow::Error::msg(
                "portal task exited unexpectedly",
            ))),
        }
    }

    async fn handle_eventloop_command(&mut self, command: Command) -> Result<ControlFlow<(), ()>> {
        match command {
            Command::Stop => return Ok(ControlFlow::Break(())),
            Command::SetDns(dns) => {
                let Some(tunnel) = self.tunnel.as_mut() else {
                    return Ok(ControlFlow::Continue(()));
                };

                let dns = tunnel.update_system_resolvers(dns);

                self.portal_cmd_tx
                    .send(PortalCommand::UpdateDnsServers(dns))
                    .await
                    .context("Failed to send message to portal")?;
            }
            Command::SetInternetResourceState(active) => {
                let Some(tunnel) = self.tunnel.as_mut() else {
                    return Ok(ControlFlow::Continue(()));
                };

                tunnel
                    .state_mut()
                    .set_internet_resource_state(active, Instant::now())
            }
            Command::SetTun(tun) => {
                let Some(tunnel) = self.tunnel.as_mut() else {
                    return Ok(ControlFlow::Continue(()));
                };

                tunnel.set_tun(tun);
            }
            Command::Reset(reason) => {
                let Some(tunnel) = self.tunnel.as_mut() else {
                    return Ok(ControlFlow::Continue(()));
                };

                tunnel.reset(&reason);
                self.portal_cmd_tx
                    .send(PortalCommand::Connect(PublicKeyParam(
                        tunnel.public_key().to_bytes(),
                    )))
                    .await
                    .context("Failed to connect phoenix-channel")?;
            }
        }

        Ok(ControlFlow::Continue(()))
    }

    async fn handle_tunnel_event(&mut self, event: ClientEvent) -> Result<()> {
        match event {
            ClientEvent::AddedIceCandidates {
                conn_id: ClientOrGatewayId::Gateway(gid),
                candidates,
            } => {
                tracing::debug!(%gid, ?candidates, "Sending new ICE candidates to gateway");

                self.portal_cmd_tx
                    .send(PortalCommand::Send(
                        EgressMessages::NewGatewayIceCandidates(GatewayIceCandidates {
                            gateway_id: gid,
                            candidates: Vec::from_iter(candidates),
                        }),
                    ))
                    .await
                    .context("Failed to send message to portal")?;
            }
            ClientEvent::RemovedIceCandidates {
                conn_id: ClientOrGatewayId::Gateway(gid),
                candidates,
            } => {
                tracing::debug!(%gid, ?candidates, "Sending invalidated ICE candidates to gateway");

                self.portal_cmd_tx
                    .send(PortalCommand::Send(
                        EgressMessages::InvalidateGatewayIceCandidates(GatewayIceCandidates {
                            gateway_id: gid,
                            candidates: Vec::from_iter(candidates),
                        }),
                    ))
                    .await
                    .context("Failed to send message to portal")?;
            }
            ClientEvent::AddedIceCandidates {
                conn_id: ClientOrGatewayId::Client(cid),
                candidates,
            } => {
                tracing::debug!(%cid, ?candidates, "Sending new ICE candidates to client");

                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::NewClientIceCandidates(
                        ClientIceCandidates {
                            client_id: cid,
                            candidates: Vec::from_iter(candidates),
                        },
                    )))
                    .await
                    .context("Failed to send message to portal")?;
            }
            ClientEvent::RemovedIceCandidates {
                conn_id: ClientOrGatewayId::Client(cid),
                candidates,
            } => {
                tracing::debug!(%cid, ?candidates, "Sending invalidated ICE candidates to client");

                self.portal_cmd_tx
                    .send(PortalCommand::Send(
                        EgressMessages::InvalidateClientIceCandidates(ClientIceCandidates {
                            client_id: cid,
                            candidates: Vec::from_iter(candidates),
                        }),
                    ))
                    .await
                    .context("Failed to send message to portal")?;
            }
            ClientEvent::ConnectionIntent {
                preferred_gateways,
                resource,
            } => {
                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::CreateFlow {
                        resource_id: resource,
                        preferred_gateways,
                    }))
                    .await
                    .context("Failed to send message to portal")?;
            }
            ClientEvent::ResourcesChanged { resources } => {
                self.resource_list_sender
                    .send(resources)
                    .context("Failed to emit event")?;
            }
            ClientEvent::TunInterfaceUpdated(config) => {
                self.tun_config_sender
                    .send(Some(config))
                    .context("Failed to emit event")?;
            }
            ClientEvent::DnsRecordsChanged { records } => {
                *DNS_RESOURCE_RECORDS_CACHE.lock() = records;
            }
            ClientEvent::Error(error) => self.handle_tunnel_error(error)?,
        }

        Ok(())
    }

    fn handle_tunnel_error(&mut self, mut e: TunnelError) -> Result<()> {
        for e in e.drain() {
            if e.any_downcast_ref::<io::Error>()
                .is_some_and(is_unreachable)
            {
                tracing::debug!("{e:#}"); // Log these on DEBUG so they don't go completely unnoticed.
                continue;
            }

            // Invalid Input can be all sorts of things but we mostly see it with unreachable addresses.
            if e.any_downcast_ref::<io::Error>()
                .is_some_and(|e| e.kind() == io::ErrorKind::InvalidInput)
            {
                tracing::debug!("{e:#}");
                continue;
            }

            if e.any_downcast_ref::<io::Error>()
                .is_some_and(|e| e.kind() == io::ErrorKind::PermissionDenied)
            {
                if !mem::replace(&mut self.logged_permission_denied, true) {
                    tracing::info!(
                        "Encountered `PermissionDenied` IO error. Check your local firewall rules to allow outbound STUN/TURN/WireGuard and general UDP traffic."
                    )
                }

                continue;
            }

            if e.any_is::<tunnel::UdpSocketThreadStopped>() {
                return Err(e);
            }

            tracing::warn!("Tunnel error: {e:#}");
        }

        Ok(())
    }

    async fn handle_portal_message(&mut self, msg: IngressMessages) -> Result<()> {
        let Some(tunnel) = self.tunnel.as_mut() else {
            return Ok(());
        };

        match msg {
            IngressMessages::ConfigChanged(config) => {
                tunnel.state_mut().update_interface_config(config.interface)
            }
            IngressMessages::GatewayIceCandidates(GatewayIceCandidates {
                gateway_id,
                candidates,
            }) => {
                for candidate in candidates {
                    tunnel
                        .state_mut()
                        .add_ice_candidate(gateway_id, candidate, Instant::now())
                }
            }
            IngressMessages::ClientIceCandidates(ClientIceCandidates {
                client_id,
                candidates,
            }) => {
                for candidate in candidates {
                    tunnel
                        .state_mut()
                        .add_ice_candidate(client_id, candidate, Instant::now())
                }
            }
            IngressMessages::Init(InitClient {
                interface,
                resources,
                relays,
            }) => {
                let state = tunnel.state_mut();

                state.update_interface_config(interface);
                state.set_resources(resources, Instant::now());
                state.update_relays(BTreeSet::default(), tunnel::turn(&relays), Instant::now());
            }
            IngressMessages::ResourceCreatedOrUpdated(resource) => {
                tunnel.state_mut().add_resource(resource, Instant::now());
            }
            IngressMessages::ResourceDeleted(resource) => {
                tunnel.state_mut().remove_resource(resource, Instant::now());
            }
            IngressMessages::RelaysPresence(RelaysPresence {
                disconnected_ids,
                connected,
            }) => tunnel.state_mut().update_relays(
                BTreeSet::from_iter(disconnected_ids),
                tunnel::turn(&connected),
                Instant::now(),
            ),
            IngressMessages::InvalidateGatewayIceCandidates(GatewayIceCandidates {
                gateway_id,
                candidates,
            }) => {
                for candidate in candidates {
                    tunnel
                        .state_mut()
                        .remove_ice_candidate(gateway_id, candidate, Instant::now())
                }
            }
            IngressMessages::InvalidateClientIceCandidates(ClientIceCandidates {
                client_id,
                candidates,
            }) => {
                for candidate in candidates {
                    tunnel
                        .state_mut()
                        .remove_ice_candidate(client_id, candidate, Instant::now())
                }
            }
            IngressMessages::FlowCreated(FlowCreated {
                resource_id,
                gateway_id,
                site_id,
                gateway_public_key,
                gateway_ipv4,
                gateway_ipv6,
                preshared_key,
                client_ice_credentials,
                gateway_ice_credentials,
            }) => {
                match tunnel.state_mut().handle_resource_access_authorized(
                    resource_id,
                    gateway_id,
                    PublicKey::from(gateway_public_key.0),
                    IpConfig {
                        v4: gateway_ipv4,
                        v6: gateway_ipv6,
                    },
                    site_id,
                    preshared_key,
                    client_ice_credentials,
                    gateway_ice_credentials,
                    Instant::now(),
                ) {
                    Ok(Ok(())) => {}
                    Ok(Err(e @ snownet::NoTurnServers {})) => {
                        tracing::debug!("Failed to handle flow created: {e}");

                        // Re-connecting to the portal means we will receive another `init` and thus new TURN servers.
                        self.portal_cmd_tx
                            .send(PortalCommand::Connect(PublicKeyParam(
                                tunnel.public_key().to_bytes(),
                            )))
                            .await
                            .context("Failed to connect phoenix-channel")?;
                    }
                    Err(e) => {
                        tracing::warn!("Failed to handle flow created: {e:#}");
                    }
                };
            }
            IngressMessages::FlowCreationFailed(FlowCreationFailed {
                reason,
                resource_id,
                ..
            }) => {
                tracing::debug!("Failed to create flow: {reason:?}");

                match reason {
                    FailReason::Offline => {
                        tunnel.state_mut().set_resource_offline(resource_id);

                        let _ = self
                            .user_notification_sender
                            .send(UserNotification::AllGatewaysOffline { resource_id })
                            .await;
                    }
                    FailReason::VersionMismatch => {
                        let _ = self
                            .user_notification_sender
                            .send(UserNotification::GatewayVersionMismatch { resource_id })
                            .await;
                    }
                    FailReason::NotFound | FailReason::Forbidden | FailReason::Unknown => {}
                }
            }
        }

        Ok(())
    }

    fn next_event(&mut self, cx: &mut Context) -> Poll<CombinedEvent> {
        if let Poll::Ready(cmd) = self.cmd_rx.poll_recv(cx) {
            return Poll::Ready(CombinedEvent::Command(cmd));
        }

        if let Poll::Ready(event) = self.portal_event_rx.poll_recv(cx) {
            return Poll::Ready(CombinedEvent::Portal(event));
        }

        if let Some(Poll::Ready(event)) = self.tunnel.as_mut().map(|t| t.poll_next_event(cx)) {
            return Poll::Ready(CombinedEvent::Tunnel(event));
        }

        Poll::Pending
    }

    async fn shut_down_tunnel(&mut self) -> Result<()> {
        let Some(tunnel) = self.tunnel.take() else {
            tracing::debug!("Tunnel has already been shut down");
            return Ok(());
        };

        tunnel
            .shut_down()
            .await
            .context("Failed to shut down tunnel")?;

        Ok(())
    }
}

async fn phoenix_channel_event_loop(
    mut portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
    param: PublicKeyParam,
    event_tx: mpsc::Sender<Result<IngressMessages, phoenix_channel::Error>>,
    mut cmd_rx: mpsc::Receiver<PortalCommand>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    dns_servers: Vec<IpAddr>,
) {
    use futures::future::Either;
    use futures::future::select;
    use std::future::poll_fn;

    let mut udp_dns_client = UdpDnsClient::new(udp_socket_factory.clone(), dns_servers);

    let ips = resolve_portal_host_ips(portal.host(), &udp_dns_client).await;
    portal.update_ips(ips);
    portal.connect(param);

    loop {
        // We process commands from the channel first (i.e. it is polled first) to update the DNS servers as quickly as possible.
        // This allows `NoAddresses` events to use the updated `UdpDnsClient` to resolve the domain.
        match select(pin!(cmd_rx.recv()), poll_fn(|cx| portal.poll(cx))).await {
            Either::Left((Some(PortalCommand::Send(msg)), _)) => {
                portal.send(PHOENIX_TOPIC, msg);
            }
            Either::Left((Some(PortalCommand::Connect(param)), _)) => {
                portal.connect(param);
            }
            Either::Left((Some(PortalCommand::UpdateDnsServers(servers)), _)) => {
                udp_dns_client = UdpDnsClient::new(udp_socket_factory.clone(), servers);
            }
            Either::Left((None, _)) => {
                tracing::debug!("Command channel closed: exiting phoenix-channel event-loop");

                break;
            }
            Either::Right((Ok(phoenix_channel::Event::InboundMessage { msg, .. }), _)) => {
                if event_tx.send(Ok(msg)).await.is_err() {
                    tracing::debug!("Event channel closed: exiting phoenix-channel event-loop");

                    break;
                }
            }
            Either::Right((Ok(phoenix_channel::Event::SuccessResponse { .. }), _)) => {}
            Either::Right((
                Ok(phoenix_channel::Event::ErrorResponse { res, req_id, topic }),
                _,
            )) => match res {
                ErrorReply::Disabled => {
                    tracing::debug!(%req_id, "Functionality is disabled");
                }
                ErrorReply::UnmatchedTopic => {
                    portal.join(topic, ());
                }
                reason @ (ErrorReply::InvalidVersion | ErrorReply::Other) => {
                    tracing::debug!(%req_id, %reason, "Request failed");
                }
            },
            Either::Right((Ok(phoenix_channel::Event::HeartbeatSent), _)) => {}
            Either::Right((Ok(phoenix_channel::Event::JoinedRoom { .. }), _)) => {}
            Either::Right((Ok(phoenix_channel::Event::Closed), _)) => {
                unimplemented!("Client never actively closes the portal connection")
            }
            Either::Right((
                Ok(phoenix_channel::Event::Hiccup {
                    backoff,
                    max_elapsed_time,
                    error,
                }),
                _,
            )) => {
                tracing::info!(
                    ?backoff,
                    ?max_elapsed_time,
                    "Hiccup in portal connection: {error:#}"
                );
            }
            Either::Right((Ok(phoenix_channel::Event::NoAddresses), _)) => {
                let ips = resolve_portal_host_ips(portal.host(), &udp_dns_client).await;
                portal.update_ips(ips);
            }
            Either::Right((Err(e), _)) => {
                let _ = event_tx.send(Err(e)).await; // We don't care about the result because we are exiting anyway.

                break;
            }
        }
    }
}

/// Re-resolves the IPs of the portal hostname.
///
/// We combine the result of two sources here:
///
/// - We make UDP DNS queries to our configured system resolvers.
/// - We read `/etc/hosts`.
///
/// If any of these fail, we simply default to an empty list of IPs.
/// This is fine as this routine will be triggered again if we ever run out of IPs to use.
async fn resolve_portal_host_ips(
    host: String,
    udp_dns_client: &UdpDnsClient,
) -> impl IntoIterator<Item = IpAddr> {
    let udp_ips = udp_dns_client
        .resolve(host.clone())
        .await
        .context("Failed to lookup portal host via UDP DNS")
        .inspect_err(|e| tracing::debug!(%host, "{e:#}"))
        .unwrap_or_default();

    let etc_hosts_ips = etc_hosts_dns_client::resolve(host.clone())
        .await
        .context("Failed to lookup portal host from `/etc/hosts`")
        .inspect_err(|e| tracing::debug!(%host, "{e:#}"))
        .unwrap_or_default();

    udp_ips.into_iter().chain(etc_hosts_ips)
}

fn is_unreachable(e: &io::Error) -> bool {
    #[cfg(unix)]
    if e.raw_os_error().is_some_and(|e| e == libc::EHOSTDOWN) {
        return true;
    }

    e.kind() == io::ErrorKind::NetworkUnreachable
        || e.kind() == io::ErrorKind::HostUnreachable
        || e.kind() == io::ErrorKind::AddrNotAvailable
}
