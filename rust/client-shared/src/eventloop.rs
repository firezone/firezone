use crate::PHOENIX_TOPIC;
use anyhow::{Context as _, Result};
use connlib_model::{PublicKey, ResourceId, ResourceView};
use dns_types::DomainName;
use firezone_tunnel::messages::RelaysPresence;
use firezone_tunnel::messages::client::{
    EgressMessages, FailReason, FlowCreated, FlowCreationFailed, GatewayIceCandidates,
    GatewaysIceCandidates, IngressMessages, InitClient,
};
use firezone_tunnel::{ClientEvent, ClientTunnel, IpConfig, TunConfig};
use ip_network::{Ipv4Network, Ipv6Network};
use phoenix_channel::{ErrorReply, PhoenixChannel, PublicKeyParam};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::ops::ControlFlow;
use std::pin::pin;
use std::time::Instant;
use std::{
    collections::BTreeSet,
    io,
    net::IpAddr,
    task::{Context, Poll},
};
use std::{future, mem};
use tokio::sync::mpsc;
use tun::Tun;

pub struct Eventloop {
    tunnel: ClientTunnel,

    cmd_rx: mpsc::UnboundedReceiver<Command>,
    event_tx: mpsc::Sender<Event>,

    portal_event_rx: mpsc::Receiver<PortalEvent>,
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

pub enum Event {
    TunInterfaceUpdated {
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
        search_domain: Option<DomainName>,
        ipv4_routes: Vec<Ipv4Network>,
        ipv6_routes: Vec<Ipv6Network>,
    },
    ResourcesUpdated(Vec<ResourceView>),
    Disconnected(DisconnectError),
}

impl Event {
    fn tun_interface_updated(config: TunConfig) -> Self {
        Self::TunInterfaceUpdated {
            ipv4: config.ip.v4,
            ipv6: config.ip.v6,
            dns: config.dns_by_sentinel.left_values().copied().collect(),
            search_domain: config.search_domain,
            ipv4_routes: Vec::from_iter(config.ipv4_routes),
            ipv6_routes: Vec::from_iter(config.ipv6_routes),
        }
    }
}

enum PortalCommand {
    Connect(PublicKeyParam),
    Send(EgressMessages),
}

#[expect(
    clippy::large_enum_variant,
    reason = "This type is only sent through a channel so the stack-size doesn't matter much."
)]
enum PortalEvent {
    Received(IngressMessages),
    Error(phoenix_channel::Error),
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
        tunnel: ClientTunnel,
        mut portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
        cmd_rx: mpsc::UnboundedReceiver<Command>,
        event_tx: mpsc::Sender<Event>,
    ) -> Self {
        let (portal_event_tx, portal_event_rx) = mpsc::channel(128);
        let (portal_cmd_tx, portal_cmd_rx) = mpsc::channel(128);

        portal.connect(PublicKeyParam(tunnel.public_key().to_bytes()));

        tokio::spawn(phoenix_channel_event_loop(
            portal,
            portal_event_tx,
            portal_cmd_rx,
        ));

        Self {
            tunnel,
            cmd_rx,
            event_tx,
            logged_permission_denied: false,
            portal_event_rx,
            portal_cmd_tx,
        }
    }
}

enum CombinedEvent {
    Command(Option<Command>),
    Tunnel(Result<ClientEvent>),
    Portal(Option<PortalEvent>),
}

impl Eventloop {
    pub async fn run(mut self) -> Result<()> {
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
                CombinedEvent::Portal(Some(PortalEvent::Received(msg))) => {
                    self.handle_portal_message(msg).await?;
                }
                CombinedEvent::Portal(Some(PortalEvent::Error(e))) => {
                    return Err(e).context("Connection to portal failed");
                }
                CombinedEvent::Portal(None) => {
                    return Err(anyhow::Error::msg("portal task exited unexpectedly"));
                }
            }
        }
    }

    async fn handle_eventloop_command(&mut self, command: Command) -> Result<ControlFlow<(), ()>> {
        match command {
            Command::Stop => return Ok(ControlFlow::Break(())),
            Command::SetDns(dns) => self.tunnel.state_mut().update_system_resolvers(dns),
            Command::SetDisabledResources(resources) => {
                self.tunnel.state_mut().set_disabled_resources(resources)
            }
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
                self.event_tx
                    .send(Event::ResourcesUpdated(resources))
                    .await
                    .context("Failed to emit event")?;
            }
            ClientEvent::TunInterfaceUpdated(config) => {
                self.event_tx
                    .send(Event::tun_interface_updated(config))
                    .await
                    .context("Failed to emit event")?;
            }
        }

        Ok(())
    }

    fn handle_tunnel_error(&mut self, e: anyhow::Error) -> Result<()> {
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
                state.set_resources(resources);
                state.update_relays(
                    BTreeSet::default(),
                    firezone_tunnel::turn(&relays),
                    Instant::now(),
                );
            }
            IngressMessages::ResourceCreatedOrUpdated(resource) => {
                self.tunnel.state_mut().add_resource(resource);
            }
            IngressMessages::ResourceDeleted(resource) => {
                self.tunnel.state_mut().remove_resource(resource);
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
    event_tx: mpsc::Sender<PortalEvent>,
    mut cmd_rx: mpsc::Receiver<PortalCommand>,
) {
    use futures::future::Either;
    use futures::future::select;
    use std::future::poll_fn;

    loop {
        match select(poll_fn(|cx| portal.poll(cx)), pin!(cmd_rx.recv())).await {
            Either::Left((Ok(phoenix_channel::Event::InboundMessage { msg, .. }), _)) => {
                if event_tx.send(PortalEvent::Received(msg)).await.is_err() {
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
                let _ = event_tx.send(PortalEvent::Error(e)).await; // We don't care about the result because we ar exiting anyway.

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
