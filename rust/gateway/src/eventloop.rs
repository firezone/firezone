use crate::messages::{
    AllowAccess, BroadcastClientIceCandidates, ClientIceCandidates, ConnectionReady,
    EgressMessages, IngressMessages,
};
use crate::CallbackHandler;
use anyhow::Result;
use connlib_shared::messages::{ConnectionAccepted, GatewayResponse};
use firezone_tunnel::{gateway, Tunnel};
use phoenix_channel::PhoenixChannel;
use std::convert::Infallible;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use str0m::Candidate;

pub const PHOENIX_TOPIC: &str = "gateway";

pub struct Eventloop {
    tunnel: Arc<Tunnel<CallbackHandler, gateway::State>>,
    portal: PhoenixChannel<IngressMessages, ()>,

    print_stats_timer: tokio::time::Interval,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: Arc<Tunnel<CallbackHandler, gateway::State>>,
        portal: PhoenixChannel<IngressMessages, ()>,
    ) -> Self {
        Self {
            tunnel,
            portal,
            print_stats_timer: tokio::time::interval(Duration::from_secs(10)),
        }
    }
}

impl Eventloop {
    #[tracing::instrument(name = "Eventloop::poll", skip_all, level = "debug")]
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<Infallible>> {
        loop {
            match self.portal.poll(cx)? {
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg: IngressMessages::RequestConnection(req),
                    ..
                }) => {
                    let parameters = self.tunnel.set_peer_connection_request(
                        req.client.payload.ice_parameters,
                        req.client.peer.into(),
                        req.relays,
                        req.client.id,
                        req.expires_at,
                        req.resource,
                    )?;

                    let _id = self.portal.send(
                        PHOENIX_TOPIC,
                        EgressMessages::ConnectionReady(ConnectionReady {
                            reference: req.reference,
                            gateway_payload: GatewayResponse::ConnectionAccepted(
                                ConnectionAccepted {
                                    ice_parameters: parameters,
                                    domain_response: None, // TODO?
                                },
                            ),
                        }),
                    );

                    continue;
                }
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg:
                        IngressMessages::AllowAccess(AllowAccess {
                            client_id,
                            resource,
                            expires_at,
                            payload,
                            reference,
                        }),
                    ..
                }) => {
                    tracing::debug!(client = %client_id, resource = %resource.id(), expires = %expires_at.to_rfc3339() ,"Allowing access to resource");

                    self.tunnel.allow_access(resource, client_id, expires_at);
                    continue;
                }
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg:
                        IngressMessages::IceCandidates(ClientIceCandidates {
                            client_id,
                            candidates,
                        }),
                    ..
                }) => {
                    for candidate in candidates {
                        if let Ok(c) = Candidate::from_sdp_string(&candidate) {
                            self.tunnel.add_ice_candidate(client_id, c)
                        }
                    }
                    continue;
                }
                _ => {}
            }

            match self.tunnel.poll_next_event(cx)? {
                Poll::Ready(gateway::Event::SignalIceCandidate {
                    conn_id: client,
                    candidate,
                }) => {
                    tracing::debug!(%client, %candidate, "Sending ICE candidate to client");

                    let _id = self.portal.send(
                        PHOENIX_TOPIC,
                        EgressMessages::BroadcastIceCandidates(BroadcastClientIceCandidates {
                            client_ids: vec![client],
                            candidates: vec![candidate.to_sdp_string()],
                        }),
                    );
                    continue;
                }
                Poll::Pending => {}
            }

            if self.print_stats_timer.poll_tick(cx).is_ready() {
                // tracing::debug!(target: "tunnel_state", stats = ?self.tunnel.stats());
                continue;
            }

            return Poll::Pending;
        }
    }
}
