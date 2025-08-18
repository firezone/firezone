use crate::PHOENIX_TOPIC;
use anyhow::{Context as _, Result};
use connlib_model::{PublicKey, ResourceId, ResourceView};
use dns_types::DomainName;
use firezone_tunnel::messages::RelaysPresence;
use firezone_tunnel::messages::client::{
    EgressMessages, FailReason, FlowCreated, FlowCreationFailed, GatewayIceCandidates,
    GatewaysIceCandidates, IngressMessages, InitClient,
};
use firezone_tunnel::{ClientTunnel, IpConfig};
use ip_network::{Ipv4Network, Ipv6Network};
use phoenix_channel::{ErrorReply, PhoenixChannel, PublicKeyParam};
use std::mem;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::pin::pin;
use std::time::Instant;
use std::{
    collections::BTreeSet,
    io,
    net::IpAddr,
    task::{Context, Poll},
};
use tokio::sync::mpsc;
use tokio::sync::mpsc::error::TrySendError;
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
        portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
        cmd_rx: mpsc::UnboundedReceiver<Command>,
        event_tx: mpsc::Sender<Event>,
    ) -> Self {
        let (portal_event_tx, portal_event_rx) = mpsc::channel(128);
        let (portal_cmd_tx, portal_cmd_rx) = mpsc::channel(128);

        let _ = portal_cmd_tx.try_send(PortalCommand::Connect(PublicKeyParam(
            tunnel.public_key().to_bytes(),
        )));

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

impl Eventloop {
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        loop {
            match self.cmd_rx.poll_recv(cx) {
                Poll::Ready(None | Some(Command::Stop)) => return Poll::Ready(Ok(())),
                Poll::Ready(Some(Command::SetDns(dns))) => {
                    self.tunnel.state_mut().update_system_resolvers(dns);

                    continue;
                }
                Poll::Ready(Some(Command::SetDisabledResources(resources))) => {
                    self.tunnel.state_mut().set_disabled_resources(resources);
                    continue;
                }
                Poll::Ready(Some(Command::SetTun(tun))) => {
                    self.tunnel.set_tun(tun);
                    continue;
                }
                Poll::Ready(Some(Command::Reset(reason))) => {
                    self.tunnel.reset(&reason);
                    self.portal_cmd_tx
                        .try_send(PortalCommand::Connect(PublicKeyParam(
                            self.tunnel.public_key().to_bytes(),
                        )));

                    continue;
                }
                Poll::Pending => {}
            }

            match self.tunnel.poll_next_event(cx) {
                Poll::Ready(Ok(event)) => {
                    let Some(e) = self.handle_tunnel_event(event) else {
                        continue;
                    };

                    match self.event_tx.try_send(e) {
                        Ok(()) => {}
                        Err(TrySendError::Closed(_)) => {
                            tracing::debug!("Event receiver dropped, exiting event loop");

                            return Poll::Ready(Ok(()));
                        }
                        Err(TrySendError::Full(_)) => {
                            tracing::warn!("App cannot keep up with connlib events, dropping");
                        }
                    };

                    continue;
                }
                Poll::Ready(Err(e)) => {
                    if e.root_cause()
                        .downcast_ref::<io::Error>()
                        .is_some_and(is_unreachable)
                    {
                        tracing::debug!("{e:#}"); // Log these on DEBUG so they don't go completely unnoticed.
                        continue;
                    }

                    // Invalid Input can be all sorts of things but we mostly see it with unreachable addresses.
                    if e.root_cause()
                        .downcast_ref::<io::Error>()
                        .is_some_and(|e| e.kind() == io::ErrorKind::InvalidInput)
                    {
                        tracing::debug!("{e:#}");
                        continue;
                    }

                    if e.root_cause()
                        .is::<firezone_tunnel::UdpSocketThreadStopped>()
                    {
                        return Poll::Ready(Err(e));
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

                        continue;
                    }

                    tracing::warn!("Tunnel error: {e:#}");
                    continue;
                }
                Poll::Pending => {}
            }

            match self.portal_event_rx.poll_recv(cx) {
                Poll::Ready(Some(PortalEvent::Received(msg))) => {
                    self.handle_portal_inbound_message(msg);
                    continue;
                }
                Poll::Ready(Some(PortalEvent::Error(e))) => {
                    return Poll::Ready(Err(e).context("Connection to portal failed"));
                }
                Poll::Ready(None) => {
                    return Poll::Ready(Err(anyhow::Error::msg("portal task exited unexpectedly")));
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }

    fn handle_tunnel_event(&mut self, event: firezone_tunnel::ClientEvent) -> Option<Event> {
        match event {
            firezone_tunnel::ClientEvent::AddedIceCandidates {
                conn_id: gid,
                candidates,
            } => {
                tracing::debug!(%gid, ?candidates, "Sending new ICE candidates to gateway");

                self.portal_cmd_tx.try_send(PortalCommand::Send(
                    EgressMessages::BroadcastIceCandidates(GatewaysIceCandidates {
                        gateway_ids: vec![gid],
                        candidates,
                    }),
                ));

                None
            }
            firezone_tunnel::ClientEvent::RemovedIceCandidates {
                conn_id: gid,
                candidates,
            } => {
                tracing::debug!(%gid, ?candidates, "Sending invalidated ICE candidates to gateway");

                self.portal_cmd_tx.try_send(PortalCommand::Send(
                    EgressMessages::BroadcastInvalidatedIceCandidates(GatewaysIceCandidates {
                        gateway_ids: vec![gid],
                        candidates,
                    }),
                ));

                None
            }
            firezone_tunnel::ClientEvent::ConnectionIntent {
                connected_gateway_ids,
                resource,
            } => {
                self.portal_cmd_tx
                    .try_send(PortalCommand::Send(EgressMessages::CreateFlow {
                        resource_id: resource,
                        connected_gateway_ids,
                    }));

                None
            }
            firezone_tunnel::ClientEvent::ResourcesChanged { resources } => {
                Some(Event::ResourcesUpdated(resources))
            }
            firezone_tunnel::ClientEvent::TunInterfaceUpdated(config) => {
                Some(Event::TunInterfaceUpdated {
                    ipv4: config.ip.v4,
                    ipv6: config.ip.v6,
                    dns: config.dns_by_sentinel.left_values().copied().collect(),
                    search_domain: config.search_domain,
                    ipv4_routes: Vec::from_iter(config.ipv4_routes),
                    ipv6_routes: Vec::from_iter(config.ipv6_routes),
                })
            }
        }
    }

    fn handle_portal_inbound_message(&mut self, msg: IngressMessages) {
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
                            .try_send(PortalCommand::Connect(PublicKeyParam(
                                self.tunnel.public_key().to_bytes(),
                            )));
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
                if event_tx.send(PortalEvent::Error(e)).await.is_err() {
                    tracing::debug!("Event channel closed: exiting phoenix-channel event-loop");
                    break;
                }
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
