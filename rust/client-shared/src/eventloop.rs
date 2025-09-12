use crate::PHOENIX_TOPIC;
use anyhow::{Context as _, Result};
use connlib_model::{PublicKey, ResourceId, ResourceView};
use firezone_tunnel::messages::RelaysPresence;
use firezone_tunnel::messages::client::{
    EgressMessages, FailReason, FlowCreated, FlowCreationFailed, GatewayIceCandidates,
    GatewaysIceCandidates, IngressMessages, InitClient,
};
use firezone_tunnel::{
    ClientEvent, ClientTunnel, DnsResourceRecord, IpConfig, TunConfig, TunnelError,
};
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
    tunnel: ClientTunnel,

    cmd_rx: mpsc::UnboundedReceiver<Command>,
    resource_list_sender: watch::Sender<Vec<ResourceView>>,
    tun_config_sender: watch::Sender<Option<TunConfig>>,

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
    SetDisabledResources(BTreeSet<ResourceId>),
}

enum PortalCommand {
    Connect(PublicKeyParam),
    Send(EgressMessages),
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
        let Some(e) = self.0.downcast_ref::<phoenix_channel::Error>() else {
            return false;
        };

        e.is_authentication_error()
    }
}

impl Eventloop {
    pub(crate) fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        mut portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
        cmd_rx: mpsc::UnboundedReceiver<Command>,
        resource_list_sender: watch::Sender<Vec<ResourceView>>,
        tun_config_sender: watch::Sender<Option<TunConfig>>,
    ) -> Self {
        let (portal_event_tx, portal_event_rx) = mpsc::channel(128);
        let (portal_cmd_tx, portal_cmd_rx) = mpsc::channel(128);

        let tunnel = ClientTunnel::new(
            tcp_socket_factory,
            udp_socket_factory,
            DNS_RESOURCE_RECORDS_CACHE.lock().clone(),
        );

        portal.connect(PublicKeyParam(tunnel.public_key().to_bytes()));

        tokio::spawn(phoenix_channel_event_loop(
            portal,
            portal_event_tx,
            portal_cmd_rx,
        ));

        Self {
            tunnel,
            cmd_rx,
            logged_permission_denied: false,
            portal_event_rx,
            portal_cmd_tx,
            resource_list_sender,
            tun_config_sender,
        }
    }
}

enum CombinedEvent {
    Command(Option<Command>),
    Tunnel(Result<ClientEvent, TunnelError>),
    Portal(Option<Result<IngressMessages, phoenix_channel::Error>>),
}

impl Eventloop {
    pub async fn run(mut self) -> Result<(), DisconnectError> {
        loop {
            match future::poll_fn(|cx| self.next_event(cx)).await {
                CombinedEvent::Command(None) => return Ok(()),
                CombinedEvent::Command(Some(cmd)) => {
                    match self.handle_eventloop_command(cmd).await? {
                        ControlFlow::Continue(()) => {}
                        ControlFlow::Break(()) => return Ok(()),
                    }
                }
                CombinedEvent::Tunnel(Ok(event)) => self.handle_tunnel_event(event).await?,
                CombinedEvent::Tunnel(Err(e)) => self.handle_tunnel_error(e)?,
                CombinedEvent::Portal(Some(event)) => {
                    let msg = event.context("Connection to portal failed")?;

                    self.handle_portal_message(msg).await?;
                }
                CombinedEvent::Portal(None) => {
                    return Err(DisconnectError(anyhow::Error::msg(
                        "portal task exited unexpectedly",
                    )));
                }
            }
        }
    }

    async fn handle_eventloop_command(&mut self, command: Command) -> Result<ControlFlow<(), ()>> {
        match command {
            Command::Stop => return Ok(ControlFlow::Break(())),
            Command::SetDns(dns) => self.tunnel.state_mut().update_system_resolvers(dns),
            Command::SetDisabledResources(resources) => self
                .tunnel
                .state_mut()
                .set_disabled_resources(resources, Instant::now()),
            Command::SetTun(tun) => {
                self.tunnel.set_tun(tun);
            }
            Command::Reset(reason) => {
                self.tunnel.reset(&reason);
                self.portal_cmd_tx
                    .send(PortalCommand::Connect(PublicKeyParam(
                        self.tunnel.public_key().to_bytes(),
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
                conn_id: gid,
                candidates,
            } => {
                tracing::debug!(%gid, ?candidates, "Sending new ICE candidates to gateway");

                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::BroadcastIceCandidates(
                        GatewaysIceCandidates {
                            gateway_ids: vec![gid],
                            candidates,
                        },
                    )))
                    .await
                    .context("Failed to send message to portal")?;
            }
            ClientEvent::RemovedIceCandidates {
                conn_id: gid,
                candidates,
            } => {
                tracing::debug!(%gid, ?candidates, "Sending invalidated ICE candidates to gateway");

                self.portal_cmd_tx
                    .send(PortalCommand::Send(
                        EgressMessages::BroadcastInvalidatedIceCandidates(GatewaysIceCandidates {
                            gateway_ids: vec![gid],
                            candidates,
                        }),
                    ))
                    .await
                    .context("Failed to send message to portal")?;
            }
            ClientEvent::ConnectionIntent {
                connected_gateway_ids,
                resource,
            } => {
                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::CreateFlow {
                        resource_id: resource,
                        connected_gateway_ids,
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
            firezone_tunnel::ClientEvent::DnsRecordsChanged { records } => {
                *DNS_RESOURCE_RECORDS_CACHE.lock() = records;
            }
        }

        Ok(())
    }

    fn handle_tunnel_error(&mut self, e: TunnelError) -> Result<()> {
        for e in e {
            if e.root_cause()
                .downcast_ref::<io::Error>()
                .is_some_and(is_unreachable)
            {
                tracing::debug!("{e:#}"); // Log these on DEBUG so they don't go completely unnoticed.
                return Ok(());
            }

            // Invalid Input can be all sorts of things but we mostly see it with unreachable addresses.
            if e.root_cause()
                .downcast_ref::<io::Error>()
                .is_some_and(|e| e.kind() == io::ErrorKind::InvalidInput)
            {
                tracing::debug!("{e:#}");
                return Ok(());
            }

            if e.root_cause()
                .is::<firezone_tunnel::UdpSocketThreadStopped>()
            {
                return Err(e);
            }

            if e.root_cause()
                .downcast_ref::<io::Error>()
                .is_some_and(|e| e.kind() == io::ErrorKind::PermissionDenied)
            {
                if !mem::replace(&mut self.logged_permission_denied, true) {
                    tracing::info!(
                        "Encountered `PermissionDenied` IO error. Check your local firewall rules to allow outbound STUN/TURN/WireGuard and general UDP traffic."
                    )
                }

                return Ok(());
            }

            tracing::warn!("Tunnel error: {e:#}");
        }

        Ok(())
    }

    async fn handle_portal_message(&mut self, msg: IngressMessages) -> Result<()> {
        match msg {
            IngressMessages::ConfigChanged(config) => self
                .tunnel
                .state_mut()
                .update_interface_config(config.interface),
            IngressMessages::IceCandidates(GatewayIceCandidates {
                gateway_id,
                candidates,
            }) => {
                for candidate in candidates {
                    self.tunnel
                        .state_mut()
                        .add_ice_candidate(gateway_id, candidate, Instant::now())
                }
            }
            IngressMessages::Init(InitClient {
                interface,
                resources,
                relays,
            }) => {
                let state = self.tunnel.state_mut();

                state.update_interface_config(interface);
                state.set_resources(resources, Instant::now());
                state.update_relays(
                    BTreeSet::default(),
                    firezone_tunnel::turn(&relays),
                    Instant::now(),
                );
            }
            IngressMessages::ResourceCreatedOrUpdated(resource) => {
                self.tunnel
                    .state_mut()
                    .add_resource(resource, Instant::now());
            }
            IngressMessages::ResourceDeleted(resource) => {
                self.tunnel
                    .state_mut()
                    .remove_resource(resource, Instant::now());
            }
            IngressMessages::RelaysPresence(RelaysPresence {
                disconnected_ids,
                connected,
            }) => self.tunnel.state_mut().update_relays(
                BTreeSet::from_iter(disconnected_ids),
                firezone_tunnel::turn(&connected),
                Instant::now(),
            ),
            IngressMessages::InvalidateIceCandidates(GatewayIceCandidates {
                gateway_id,
                candidates,
            }) => {
                for candidate in candidates {
                    self.tunnel.state_mut().remove_ice_candidate(
                        gateway_id,
                        candidate,
                        Instant::now(),
                    )
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
                match self.tunnel.state_mut().handle_flow_created(
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
                    Ok(Err(snownet::NoTurnServers {})) => {
                        tracing::debug!(
                            "Failed to request new connection: No TURN servers available"
                        );

                        // Re-connecting to the portal means we will receive another `init` and thus new TURN servers.
                        self.portal_cmd_tx
                            .send(PortalCommand::Connect(PublicKeyParam(
                                self.tunnel.public_key().to_bytes(),
                            )))
                            .await
                            .context("Failed to connect phoenix-channel")?;
                    }
                    Err(e) => {
                        tracing::warn!("Failed to request new connection: {e:#}");
                    }
                };
            }
            IngressMessages::FlowCreationFailed(FlowCreationFailed {
                resource_id,
                reason: FailReason::Offline,
                ..
            }) => {
                self.tunnel.state_mut().set_resource_offline(resource_id);
            }
            IngressMessages::FlowCreationFailed(FlowCreationFailed { reason, .. }) => {
                tracing::debug!("Failed to create flow: {reason:?}")
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

        if let Poll::Ready(event) = self.tunnel.poll_next_event(cx) {
            return Poll::Ready(CombinedEvent::Tunnel(event));
        }

        Poll::Pending
    }
}

async fn phoenix_channel_event_loop(
    mut portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
    event_tx: mpsc::Sender<Result<IngressMessages, phoenix_channel::Error>>,
    mut cmd_rx: mpsc::Receiver<PortalCommand>,
) {
    use futures::future::Either;
    use futures::future::select;
    use std::future::poll_fn;

    loop {
        match select(poll_fn(|cx| portal.poll(cx)), pin!(cmd_rx.recv())).await {
            Either::Left((Ok(phoenix_channel::Event::InboundMessage { msg, .. }), _)) => {
                if event_tx.send(Ok(msg)).await.is_err() {
                    tracing::debug!("Event channel closed: exiting phoenix-channel event-loop");

                    break;
                }
            }
            Either::Left((Ok(phoenix_channel::Event::SuccessResponse { res: (), .. }), _)) => {}
            Either::Left((Ok(phoenix_channel::Event::ErrorResponse { res, req_id, topic }), _)) => {
                match res {
                    ErrorReply::Disabled => {
                        tracing::debug!(%req_id, "Functionality is disabled");
                    }
                    ErrorReply::UnmatchedTopic => {
                        portal.join(topic, ());
                    }
                    reason @ (ErrorReply::InvalidVersion | ErrorReply::Other) => {
                        tracing::debug!(%req_id, %reason, "Request failed");
                    }
                }
            }
            Either::Left((Ok(phoenix_channel::Event::HeartbeatSent), _)) => {}
            Either::Left((Ok(phoenix_channel::Event::JoinedRoom { .. }), _)) => {}
            Either::Left((Ok(phoenix_channel::Event::Closed), _)) => {
                unimplemented!("Client never actively closes the portal connection")
            }
            Either::Left((
                Ok(phoenix_channel::Event::Hiccup {
                    backoff,
                    max_elapsed_time,
                    error,
                }),
                _,
            )) => tracing::info!(
                ?backoff,
                ?max_elapsed_time,
                "Hiccup in portal connection: {error:#}"
            ),
            Either::Left((Err(e), _)) => {
                let _ = event_tx.send(Err(e)).await; // We don't care about the result because we are exiting anyway.

                break;
            }
            Either::Right((Some(PortalCommand::Send(msg)), _)) => {
                portal.send(PHOENIX_TOPIC, msg);
            }
            Either::Right((Some(PortalCommand::Connect(param)), _)) => {
                portal.connect(param);
            }
            Either::Right((None, _)) => {
                tracing::debug!("Command channel closed: exiting phoenix-channel event-loop");

                break;
            }
        }
    }
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
