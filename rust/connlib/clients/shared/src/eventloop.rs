use crate::{callbacks::Callbacks, PHOENIX_TOPIC};
use anyhow::Result;
use connlib_model::{PublicKey, ResourceId};
use firezone_tunnel::messages::client::{CreateFlowErr, CreateFlowErrKind};
use firezone_tunnel::messages::RelaysPresence;
use firezone_tunnel::{
    messages::client::{
        CreateFlowOk, EgressMessages, GatewayIceCandidates, GatewaysIceCandidates, IngressMessages,
        InitClient,
    },
    ClientTunnel,
};
use phoenix_channel::{ErrorReply, OutboundRequestId, PhoenixChannel, PublicKeyParam};
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
                Poll::Ready(Some(Command::Stop)) | Poll::Ready(None) => return Poll::Ready(Ok(())),
                Poll::Ready(Some(Command::SetDns(dns))) => {
                    self.tunnel.set_new_dns(dns);

                    continue;
                }
                Poll::Ready(Some(Command::SetDisabledResources(resources))) => {
                    self.tunnel.set_disabled_resources(resources);
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

                self.callbacks
                    .on_set_interface_config(config.ip4, config.ip6, dns_servers);
                self.callbacks.on_update_routes(
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
        }
    }

    fn handle_portal_inbound_message(&mut self, msg: IngressMessages) {
        match msg {
            IngressMessages::ConfigChanged(config) => {
                self.tunnel.set_new_interface_config(config.interface)
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
                relays,
            }) => {
                self.tunnel.set_new_interface_config(interface);
                self.tunnel.set_resources(resources);
                self.tunnel.update_relays(BTreeSet::default(), relays);
            }
            IngressMessages::ResourceCreatedOrUpdated(resource) => {
                self.tunnel.add_resource(resource);
            }
            IngressMessages::ResourceDeleted(resource) => {
                self.tunnel.remove_resource(resource);
            }
            IngressMessages::RelaysPresence(RelaysPresence {
                disconnected_ids,
                connected,
            }) => self
                .tunnel
                .update_relays(BTreeSet::from_iter(disconnected_ids), connected),
            IngressMessages::InvalidateIceCandidates(GatewayIceCandidates {
                gateway_id,
                candidates,
            }) => {
                for candidate in candidates {
                    self.tunnel.remove_ice_candidate(gateway_id, candidate)
                }
            }
            IngressMessages::CreateFlowOk(CreateFlowOk {
                resource_id,
                gateway_id,
                site_id,
                gateway_public_key,
                preshared_key,
                client_ice_credentials,
                gateway_ice_credentials,
            }) => {
                match self.tunnel.on_create_flow_ok(
                    resource_id,
                    gateway_id,
                    PublicKey::from(gateway_public_key.0),
                    site_id,
                    preshared_key,
                    client_ice_credentials,
                    gateway_ice_credentials,
                ) {
                    Ok(()) => {}
                    Err(e) => {
                        tracing::warn!("Failed to request new connection: {e}");
                    }
                };
            }
            IngressMessages::CreateFlowErr(CreateFlowErr {
                resource_id,
                reason: CreateFlowErrKind::Offline,
            }) => {
                self.tunnel.set_resource_offline(resource_id);
            }
            IngressMessages::CreateFlowErr(CreateFlowErr {
                reason: CreateFlowErrKind::Unknown,
                ..
            }) => {
                // TODO: Still fail connection?
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
                // tracing::debug!(resource_id = %offline_resource, "Resource is offline");

                // self.tunnel.set_resource_offline(offline_resource);
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
