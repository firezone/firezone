use crate::{callbacks::Callbacks, PHOENIX_TOPIC};
use anyhow::Result;
use connlib_model::ResourceId;
use firezone_logging::{anyhow_dyn_err, err_with_sources, telemetry_event};
use firezone_tunnel::messages::{client::*, *};
use firezone_tunnel::ClientTunnel;
use phoenix_channel::{ErrorReply, OutboundRequestId, PhoenixChannel, PublicKeyParam};
use std::time::Instant;
use std::{
    collections::{BTreeMap, BTreeSet},
    io,
    net::IpAddr,
    task::{Context, Poll},
};
use tun::Tun;

pub struct Eventloop<C: Callbacks> {
    tunnel: ClientTunnel,
    callbacks: C,

    portal: PhoenixChannel<(), IngressMessages, ReplyMessages, PublicKeyParam>,
    rx: tokio::sync::mpsc::UnboundedReceiver<Command>,

    connection_intents: SentConnectionIntents,
}

/// Commands that can be sent to the [`Eventloop`].
pub enum Command {
    Stop,
    Reset,
    SetDns(Vec<IpAddr>),
    SetTun(Box<dyn Tun>),
    SetDisabledResources(BTreeSet<ResourceId>),
}

impl<C: Callbacks> Eventloop<C> {
    pub(crate) fn new(
        tunnel: ClientTunnel,
        callbacks: C,
        mut portal: PhoenixChannel<(), IngressMessages, ReplyMessages, PublicKeyParam>,
        rx: tokio::sync::mpsc::UnboundedReceiver<Command>,
    ) -> Self {
        portal.connect(PublicKeyParam(tunnel.public_key().to_bytes()));

        Self {
            tunnel,
            portal,
            connection_intents: SentConnectionIntents::default(),
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
                Poll::Ready(Some(Command::Stop)) | Poll::Ready(None) => return Poll::Ready(Ok(())),
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
                Poll::Ready(Err(e)) if e.kind() == io::ErrorKind::WouldBlock => {
                    continue;
                }
                Poll::Ready(Err(e)) => {
                    let e = err_with_sources(&e);

                    telemetry_event!("Tunnel error: {e}");
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
                ..
            } => {
                let id = self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::PrepareConnection {
                        resource_id: resource,
                        connected_gateway_ids,
                    },
                );
                self.connection_intents.register_new_intent(id, resource);
            }
            firezone_tunnel::ClientEvent::RequestAccess {
                resource_id,
                gateway_id,
                maybe_domain,
            } => {
                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::ReuseConnection(ReuseConnection {
                        resource_id,
                        gateway_id,
                        payload: maybe_domain,
                    }),
                );
            }
            firezone_tunnel::ClientEvent::ResourcesChanged { resources } => {
                self.callbacks.on_update_resources(resources)
            }
            firezone_tunnel::ClientEvent::TunInterfaceUpdated(config) => {
                let dns_servers = config.dns_by_sentinel.left_values().copied().collect();

                self.callbacks
                    .on_set_interface_config(config.ip4, config.ip6, dns_servers);
                self.callbacks.on_update_routes(
                    Vec::from_iter(config.ipv4_routes),
                    Vec::from_iter(config.ipv6_routes),
                );
            }
            firezone_tunnel::ClientEvent::RequestConnection {
                gateway_id,
                offer,
                preshared_key,
                resource_id,
                maybe_domain,
            } => {
                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::RequestConnection(RequestConnection {
                        gateway_id,
                        resource_id,
                        client_preshared_key: preshared_key,
                        client_payload: ClientPayload {
                            ice_parameters: offer,
                            domain: maybe_domain,
                        },
                    }),
                );
            }
        }
    }

    fn handle_portal_event(
        &mut self,
        event: phoenix_channel::Event<IngressMessages, ReplyMessages>,
    ) {
        match event {
            phoenix_channel::Event::InboundMessage { msg, .. } => {
                self.handle_portal_inbound_message(msg);
            }
            phoenix_channel::Event::SuccessResponse { res, req_id, .. } => {
                self.handle_portal_success_reply(res, req_id);
            }
            phoenix_channel::Event::ErrorResponse { res, req_id, topic } => {
                self.handle_portal_error_reply(res, topic, req_id);
            }
            phoenix_channel::Event::HeartbeatSent => {}
            phoenix_channel::Event::JoinedRoom { .. } => {}
            phoenix_channel::Event::Closed => {
                unimplemented!("Client never actively closes the portal connection")
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
        }
    }

    fn handle_portal_success_reply(&mut self, res: ReplyMessages, req_id: OutboundRequestId) {
        match res {
            ReplyMessages::Connect(Connect {
                gateway_payload:
                    GatewayResponse::ConnectionAccepted(ConnectionAccepted { ice_parameters, .. }),
                gateway_public_key,
                resource_id,
                ..
            }) => {
                if let Err(e) = self.tunnel.state_mut().accept_answer(
                    ice_parameters,
                    resource_id,
                    gateway_public_key.0.into(),
                    Instant::now(),
                ) {
                    tracing::warn!(error = anyhow_dyn_err(&e), "Failed to accept connection");
                }
            }
            ReplyMessages::Connect(Connect {
                gateway_payload: GatewayResponse::ResourceAccepted(ResourceAccepted { .. }),
                ..
            }) => {
                tracing::trace!("Connection response received, ignored as it's deprecated")
            }
            ReplyMessages::ConnectionDetails(ConnectionDetails {
                gateway_id,
                resource_id,
                site_id,
                ..
            }) => {
                let should_accept = self
                    .connection_intents
                    .handle_connection_details_received(req_id, resource_id);

                if !should_accept {
                    tracing::debug!(%resource_id, "Ignoring stale connection details");
                    return;
                }

                match self.tunnel.state_mut().on_routing_details(
                    resource_id,
                    gateway_id,
                    site_id,
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
                        tracing::warn!(
                            error = anyhow_dyn_err(&e),
                            "Failed to request new connection"
                        );
                    }
                };
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
            ErrorReply::Offline => {
                let Some(offline_resource) = self.connection_intents.handle_error(req_id) else {
                    return;
                };

                tracing::debug!(resource_id = %offline_resource, "Resource is offline");

                self.tunnel
                    .state_mut()
                    .set_resource_offline(offline_resource);
            }

            ErrorReply::Disabled => {
                tracing::debug!(%req_id, "Functionality is disabled");
            }
            ErrorReply::UnmatchedTopic => {
                self.portal.join(topic, ());
            }
            reason @ (ErrorReply::InvalidVersion | ErrorReply::NotFound | ErrorReply::Other) => {
                tracing::debug!(%req_id, %reason, "Request failed");
            }
        }
    }
}

#[derive(Default)]
struct SentConnectionIntents {
    inner: BTreeMap<OutboundRequestId, ResourceId>,
}

impl SentConnectionIntents {
    fn register_new_intent(&mut self, id: OutboundRequestId, resource: ResourceId) {
        self.inner.insert(id, resource);
    }

    /// To be called when we receive the connection details for a particular resource.
    ///
    /// Returns whether we should accept them.
    fn handle_connection_details_received(
        &mut self,
        reference: OutboundRequestId,
        r: ResourceId,
    ) -> bool {
        let has_more_recent_intent = self
            .inner
            .iter()
            .any(|(req, resource)| req > &reference && resource == &r);

        if has_more_recent_intent {
            return false;
        }

        let has_intent = self
            .inner
            .get(&reference)
            .is_some_and(|resource| resource == &r);

        if !has_intent {
            return false;
        }

        self.inner.retain(|_, v| v != &r);

        true
    }

    fn handle_error(&mut self, req: OutboundRequestId) -> Option<ResourceId> {
        self.inner.remove(&req)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discards_old_connection_intent() {
        let mut intents = SentConnectionIntents::default();

        let resource = ResourceId::random();

        intents.register_new_intent(OutboundRequestId::for_test(1), resource);
        intents.register_new_intent(OutboundRequestId::for_test(2), resource);

        let should_accept =
            intents.handle_connection_details_received(OutboundRequestId::for_test(1), resource);

        assert!(!should_accept);
    }

    #[test]
    fn allows_unrelated_intents() {
        let mut intents = SentConnectionIntents::default();

        let resource1 = ResourceId::random();
        let resource2 = ResourceId::random();

        intents.register_new_intent(OutboundRequestId::for_test(1), resource1);
        intents.register_new_intent(OutboundRequestId::for_test(2), resource2);

        let should_accept_1 =
            intents.handle_connection_details_received(OutboundRequestId::for_test(1), resource1);
        let should_accept_2 =
            intents.handle_connection_details_received(OutboundRequestId::for_test(2), resource2);

        assert!(should_accept_1);
        assert!(should_accept_2);
    }

    #[test]
    fn handles_out_of_order_responses() {
        let mut intents = SentConnectionIntents::default();

        let resource = ResourceId::random();

        intents.register_new_intent(OutboundRequestId::for_test(1), resource);
        intents.register_new_intent(OutboundRequestId::for_test(2), resource);

        let should_accept_2 =
            intents.handle_connection_details_received(OutboundRequestId::for_test(2), resource);
        let should_accept_1 =
            intents.handle_connection_details_received(OutboundRequestId::for_test(1), resource);

        assert!(should_accept_2);
        assert!(!should_accept_1);
    }
}
