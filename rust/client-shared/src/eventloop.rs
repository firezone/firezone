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
use phoenix_channel::{ErrorReply, OutboundRequestId, PhoenixChannel, PublicKeyParam};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::time::Instant;
use std::{
    collections::BTreeSet,
    io,
    net::IpAddr,
    task::{Context, Poll},
};
use tokio::sync::mpsc::error::TrySendError;
use tun::Tun;

pub struct Eventloop {
    tunnel: ClientTunnel,

    portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
    cmd_rx: tokio::sync::mpsc::UnboundedReceiver<Command>,
    event_tx: tokio::sync::mpsc::Sender<Event>,
}

/// Commands that can be sent to the [`Eventloop`].
pub enum Command {
    Reset,
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
        cmd_rx: tokio::sync::mpsc::UnboundedReceiver<Command>,
        event_tx: tokio::sync::mpsc::Sender<Event>,
    ) -> Self {
        portal.connect(PublicKeyParam(tunnel.public_key().to_bytes()));

        Self {
            tunnel,
            portal,
            cmd_rx,
            event_tx,
        }
    }
}

impl Eventloop {
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        loop {
            match self.cmd_rx.poll_recv(cx) {
                Poll::Ready(None) => return Poll::Ready(Ok(())),
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
                Poll::Ready(Some(Command::Reset)) => {
                    self.tunnel.reset();
                    self.portal
                        .connect(PublicKeyParam(self.tunnel.public_key().to_bytes()));

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
                    if e.root_cause().downcast_ref::<io::Error>().is_some_and(|e| {
                        e.kind() == io::ErrorKind::NetworkUnreachable
                            || e.kind() == io::ErrorKind::HostUnreachable
                            || e.kind() == io::ErrorKind::AddrNotAvailable
                    }) {
                        // `NetworkUnreachable`, `HostUnreachable`, `AddrNotAvailable` most likely means we don't have IPv4 or IPv6 connectivity.
                        tracing::debug!("{e:#}"); // Log these on DEBUG so they don't go completely unnoticed.
                        continue;
                    }

                    if e.root_cause()
                        .is::<firezone_tunnel::UdpSocketThreadStopped>()
                    {
                        return Poll::Ready(Err(e));
                    }

                    tracing::warn!("Tunnel error: {e:#}");
                    continue;
                }
                Poll::Pending => {}
            }

            match self.portal.poll(cx) {
                Poll::Ready(result) => {
                    let event = result.context("connection to the portal failed")?;
                    self.handle_portal_event(event);
                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }

    fn handle_tunnel_event(&mut self, event: firezone_tunnel::ClientEvent) -> Option<Event> {
        match event {
            firezone_tunnel::ClientEvent::AddedIceCandidates {
                conn_id: gateway,
                candidates,
            } => {
                tracing::debug!(%gateway, ?candidates, "Sending new ICE candidates to gateway");

                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::BroadcastIceCandidates(GatewaysIceCandidates {
                        gateway_ids: vec![gateway],
                        candidates,
                    }),
                );

                None
            }
            firezone_tunnel::ClientEvent::RemovedIceCandidates {
                conn_id: gateway,
                candidates,
            } => {
                tracing::debug!(%gateway, ?candidates, "Sending invalidated ICE candidates to gateway");

                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::BroadcastInvalidatedIceCandidates(GatewaysIceCandidates {
                        gateway_ids: vec![gateway],
                        candidates,
                    }),
                );

                None
            }
            firezone_tunnel::ClientEvent::ConnectionIntent {
                connected_gateway_ids,
                resource,
            } => {
                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::CreateFlow {
                        resource_id: resource,
                        connected_gateway_ids,
                    },
                );

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

    fn handle_portal_event(&mut self, event: phoenix_channel::Event<IngressMessages, ()>) {
        match event {
            phoenix_channel::Event::InboundMessage { msg, .. } => {
                self.handle_portal_inbound_message(msg);
            }
            phoenix_channel::Event::SuccessResponse { res: (), .. } => {}
            phoenix_channel::Event::ErrorResponse { res, req_id, topic } => {
                self.handle_portal_error_reply(res, topic, req_id);
            }
            phoenix_channel::Event::HeartbeatSent => {}
            phoenix_channel::Event::JoinedRoom { .. } => {}
            phoenix_channel::Event::Closed => {
                unimplemented!("Client never actively closes the portal connection")
            }
            phoenix_channel::Event::Hiccup {
                backoff,
                max_elapsed_time,
                error,
            } => tracing::debug!(?backoff, ?max_elapsed_time, "{error:#}"),
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
                        self.portal
                            .connect(PublicKeyParam(self.tunnel.public_key().to_bytes()));
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

    fn handle_portal_error_reply(
        &mut self,
        res: ErrorReply,
        topic: String,
        req_id: OutboundRequestId,
    ) {
        match res {
            ErrorReply::Disabled => {
                tracing::debug!(%req_id, "Functionality is disabled");
            }
            ErrorReply::UnmatchedTopic => {
                self.portal.join(topic, ());
            }
            reason @ (ErrorReply::InvalidVersion | ErrorReply::Other) => {
                tracing::debug!(%req_id, %reason, "Request failed");
            }
        }
    }
}
