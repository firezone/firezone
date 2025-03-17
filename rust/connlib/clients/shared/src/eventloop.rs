use crate::{callbacks::Callbacks, PHOENIX_TOPIC};
use anyhow::Result;
use connlib_model::{PublicKey, ResourceId};
use firezone_logging::{err_with_src, telemetry_event};
use firezone_tunnel::messages::client::{
    EgressMessages, FailReason, FlowCreated, FlowCreationFailed, GatewayIceCandidates,
    GatewaysIceCandidates, IngressMessages, InitClient,
};
use firezone_tunnel::messages::RelaysPresence;
use firezone_tunnel::{ClientTunnel, IpConfig};
use phoenix_channel::{ErrorReply, OutboundRequestId, PhoenixChannel, PublicKeyParam};
use std::time::Instant;
use std::{
    collections::BTreeSet,
    io,
    net::IpAddr,
    task::{Context, Poll},
};
use tun::Tun;

pub struct Eventloop<C: Callbacks> {
    tunnel: ClientTunnel,
    callbacks: C,

    portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
    rx: tokio::sync::mpsc::UnboundedReceiver<Command>,
}

/// Commands that can be sent to the [`Eventloop`].
pub enum Command {
    Reset,
    SetDns(Vec<IpAddr>),
    SetTun(Box<dyn Tun>),
    SetDisabledResources(BTreeSet<ResourceId>),
}

impl<C: Callbacks> Eventloop<C> {
    pub(crate) fn new(
        tunnel: ClientTunnel,
        callbacks: C,
        mut portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
        rx: tokio::sync::mpsc::UnboundedReceiver<Command>,
    ) -> Self {
        portal.connect(PublicKeyParam(tunnel.public_key().to_bytes()));

        Self {
            tunnel,
            portal,
            rx,
            callbacks,
        }
    }
}

impl<C> Eventloop<C>
where
    C: Callbacks + 'static,
{
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), phoenix_channel::Error>> {
        loop {
            match self.rx.poll_recv(cx) {
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
                    self.handle_tunnel_event(event);
                    continue;
                }
                Poll::Ready(Err(e))
                    if e.kind() == io::ErrorKind::NetworkUnreachable
                        || e.kind() == io::ErrorKind::HostUnreachable =>
                {
                    // Network unreachable most likely means we don't have IPv4 or IPv6 connectivity.
                    continue;
                }
                Poll::Ready(Err(e)) => {
                    debug_assert_ne!(
                        e.kind(),
                        io::ErrorKind::WouldBlock,
                        "Tunnel should never emit WouldBlock errors but suspend instead"
                    );
                    telemetry_event!("Tunnel error: {}", err_with_src(&e));
                    continue;
                }
                Poll::Pending => {}
            }

            match self.portal.poll(cx)? {
                Poll::Ready(event) => {
                    self.handle_portal_event(event);
                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }

    fn handle_tunnel_event(&mut self, event: firezone_tunnel::ClientEvent) {
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
            }
            firezone_tunnel::ClientEvent::ResourcesChanged { resources } => {
                self.callbacks.on_update_resources(resources)
            }
            firezone_tunnel::ClientEvent::TunInterfaceUpdated(config) => {
                let dns_servers = config.dns_by_sentinel.left_values().copied().collect();

                self.callbacks.on_set_interface_config(
                    config.ip.v4,
                    config.ip.v6,
                    dns_servers,
                    config.search_domain,
                    Vec::from_iter(config.ipv4_routes),
                    Vec::from_iter(config.ipv6_routes),
                );
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
