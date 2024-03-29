use crate::{
    messages::{
        BroadcastGatewayIceCandidates, Connect, ConnectionDetails, EgressMessages,
        GatewayIceCandidates, IngressMessages, InitClient, RemoveResource, ReplyMessages,
    },
    PHOENIX_TOPIC,
};
use anyhow::Result;
use connlib_shared::{
    messages::{ConnectionAccepted, GatewayResponse, ResourceAccepted, ResourceId},
    Callbacks,
};
use firezone_tunnel::ClientTunnel;
use phoenix_channel::{ErrorReply, OutboundRequestId, PhoenixChannel};
use std::{
    collections::HashMap,
    net::IpAddr,
    task::{Context, Poll},
};

pub struct Eventloop<C: Callbacks> {
    tunnel: ClientTunnel<C>,

    portal: PhoenixChannel<(), IngressMessages, ReplyMessages>,
    rx: tokio::sync::mpsc::UnboundedReceiver<Command>,

    connection_intents: SentConnectionIntents,
}

/// Commands that can be sent to the [`Eventloop`].
pub enum Command {
    Stop,
    Reconnect,
    SetDns(Vec<IpAddr>),
}

impl<C: Callbacks> Eventloop<C> {
    pub(crate) fn new(
        tunnel: ClientTunnel<C>,
        portal: PhoenixChannel<(), IngressMessages, ReplyMessages>,
        rx: tokio::sync::mpsc::UnboundedReceiver<Command>,
    ) -> Self {
        Self {
            tunnel,
            portal,
            connection_intents: SentConnectionIntents::default(),
            rx,
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
                    if let Err(e) = self.tunnel.set_dns(dns) {
                        tracing::warn!("Failed to update DNS: {e}");
                    }
                }
                Poll::Ready(Some(Command::Reconnect)) => {
                    self.portal.reconnect();
                    if let Err(e) = self.tunnel.reconnect() {
                        tracing::warn!("Failed to reconnect tunnel: {e}");
                    }

                    continue;
                }
                Poll::Pending => {}
            }

            match self.tunnel.poll_next_event(cx) {
                Poll::Ready(Ok(event)) => {
                    self.handle_tunnel_event(event);
                    continue;
                }
                Poll::Ready(Err(e)) => {
                    tracing::warn!("Tunnel error: {e}");
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
            firezone_tunnel::ClientEvent::SignalIceCandidate {
                conn_id: gateway,
                candidate,
            } => {
                tracing::debug!(%gateway, %candidate, "Sending ICE candidate to gateway");

                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::BroadcastIceCandidates(BroadcastGatewayIceCandidates {
                        gateway_ids: vec![gateway],
                        candidates: vec![candidate],
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
            firezone_tunnel::ClientEvent::RefreshResources { connections } => {
                for connection in connections {
                    self.portal
                        .send(PHOENIX_TOPIC, EgressMessages::ReuseConnection(connection));
                }
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
        }
    }

    fn handle_portal_inbound_message(&mut self, msg: IngressMessages) {
        match msg {
            IngressMessages::ConfigChanged(config) => {
                if let Err(e) = self.tunnel.set_interface(config.interface.clone()) {
                    tracing::warn!(?config, "Failed to update configuration: {e:?}");
                }
            }
            IngressMessages::IceCandidates(GatewayIceCandidates {
                gateway_id,
                candidates,
            }) => {
                for candidate in candidates {
                    self.tunnel.add_ice_candidate(gateway_id, candidate)
                }
            }
            IngressMessages::Init(InitClient {
                interface,
                resources,
            }) => {
                if let Err(e) = self.tunnel.set_interface(interface) {
                    tracing::warn!("Failed to set interface on tunnel: {e}");
                    return;
                }

                tracing::info!("Firezone Started!");
                let _ = self.tunnel.set_resources(resources);
            }
            IngressMessages::ResourceCreatedOrUpdated(resource) => {
                let resource_id = resource.id();

                if let Err(e) = self.tunnel.add_resources(&[resource]) {
                    tracing::warn!(%resource_id, "Failed to add resource: {e}");
                }
            }
            IngressMessages::ResourceDeleted(RemoveResource(resource)) => {
                self.tunnel.remove_resources(&[resource]);
            }
        }
    }

    fn handle_portal_success_reply(&mut self, res: ReplyMessages, req_id: OutboundRequestId) {
        match res {
            ReplyMessages::Connect(Connect {
                gateway_payload:
                    GatewayResponse::ConnectionAccepted(ConnectionAccepted {
                        ice_parameters,
                        domain_response,
                    }),
                gateway_public_key,
                resource_id,
                ..
            }) => {
                if let Err(e) = self.tunnel.received_offer_response(
                    resource_id,
                    ice_parameters,
                    domain_response,
                    gateway_public_key.0.into(),
                ) {
                    tracing::warn!("Failed to accept connection: {e}");
                }
            }
            ReplyMessages::Connect(Connect {
                gateway_payload:
                    GatewayResponse::ResourceAccepted(ResourceAccepted { domain_response }),
                resource_id,
                ..
            }) => {
                if let Err(e) = self
                    .tunnel
                    .received_domain_parameters(resource_id, domain_response)
                {
                    tracing::warn!("Failed to accept resource: {e}");
                }
            }
            ReplyMessages::ConnectionDetails(ConnectionDetails {
                gateway_id,
                resource_id,
                relays,
                ..
            }) => {
                let should_accept = self
                    .connection_intents
                    .handle_connection_details_received(req_id, resource_id);

                if !should_accept {
                    tracing::debug!(%resource_id, "Ignoring stale connection details");
                    return;
                }

                match self
                    .tunnel
                    .create_or_reuse_connection(resource_id, gateway_id, relays)
                {
                    Ok(firezone_tunnel::Request::NewConnection(connection_request)) => {
                        // TODO: keep track for the response
                        let _id = self.portal.send(
                            PHOENIX_TOPIC,
                            EgressMessages::RequestConnection(connection_request),
                        );
                    }
                    Ok(firezone_tunnel::Request::ReuseConnection(connection_request)) => {
                        // TODO: keep track for the response
                        let _id = self.portal.send(
                            PHOENIX_TOPIC,
                            EgressMessages::ReuseConnection(connection_request),
                        );
                    }
                    Err(e) => {
                        self.tunnel.cleanup_connection(resource_id);
                        tracing::warn!("Failed to request new connection: {e}");
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

                self.tunnel.cleanup_connection(offline_resource);
            }

            ErrorReply::Disabled => {
                tracing::debug!(%req_id, "Functionality is disabled");
            }
            ErrorReply::UnmatchedTopic => {
                self.portal.join(topic, ());
            }
            ErrorReply::NotFound | ErrorReply::Other => {}
        }
    }
}

#[derive(Default)]
struct SentConnectionIntents {
    inner: HashMap<OutboundRequestId, ResourceId>,
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
