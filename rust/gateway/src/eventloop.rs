use crate::messages::{
    AllowAccess, BroadcastClientIceCandidates, ClientIceCandidates, ConnectionReady,
    EgressMessages, IngressMessages,
};
use crate::CallbackHandler;
use anyhow::Result;
use connlib_shared::Error;
use firezone_tunnel::{gateway, Tunnel};
use phoenix_channel::PhoenixChannel;
use std::convert::Infallible;
use std::task::{Context, Poll};
use std::time::Duration;

pub const PHOENIX_TOPIC: &str = "gateway";

pub struct Eventloop<'t> {
    tunnel: &'t Tunnel<CallbackHandler, gateway::State>,
    portal: PhoenixChannel<IngressMessages, ()>,

    add_ice_candidate_tasks: futures_bounded::FuturesSet<Result<(), Error>>,

    print_stats_timer: tokio::time::Interval,
}

impl<'t> Eventloop<'t> {
    pub(crate) fn new(
        tunnel: &'t Tunnel<CallbackHandler, gateway::State>,
        portal: PhoenixChannel<IngressMessages, ()>,
    ) -> Self {
        Self {
            tunnel,
            portal,
            // TODO: Pick sane values for timeouts and size.
            add_ice_candidate_tasks: futures_bounded::FuturesSet::new(Duration::from_secs(60), 100),
            print_stats_timer: tokio::time::interval(Duration::from_secs(10)),
        }
    }
}

impl<'t> Eventloop<'t> {
    #[tracing::instrument(name = "Eventloop::poll", skip_all, level = "debug")]
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<Infallible>> {
        loop {
            match self.add_ice_candidate_tasks.poll_unpin(cx) {
                Poll::Ready(Ok(Ok(()))) => {
                    continue;
                }
                Poll::Ready(Ok(Err(e))) => {
                    tracing::error!("Failed to add ICE candidate: {:#}", anyhow::Error::new(e));

                    continue;
                }
                Poll::Ready(Err(e)) => {
                    tracing::error!("Failed to add ICE candidate: {e}");
                    continue;
                }
                Poll::Pending => {}
            }

            match self.portal.poll(cx)? {
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg: IngressMessages::RequestConnection(req),
                    ..
                }) => {
                    self.tunnel.set_peer_connection_request(
                        req.client.id,
                        req.reference,
                        req.client.rtc_session_description,
                        req.client.peer.into(),
                        req.relays,
                        req.expires_at,
                        req.resource,
                    );
                    continue;
                }
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg:
                        IngressMessages::AllowAccess(AllowAccess {
                            client_id,
                            resource,
                            expires_at,
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
                        tracing::debug!(client = %client_id, candidate = %candidate.candidate, "Adding ICE candidate from client");

                        if self
                            .add_ice_candidate_tasks
                            .try_push(self.tunnel.add_ice_candidate(client_id, candidate))
                            .is_err()
                        {
                            tracing::debug!("Received too many ICE candidates, dropping some");
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
                    tracing::debug!(%client, candidate = %candidate.candidate, "Sending ICE candidate to client");

                    let _id = self.portal.send(
                        PHOENIX_TOPIC,
                        EgressMessages::BroadcastIceCandidates(BroadcastClientIceCandidates {
                            client_ids: vec![client],
                            candidates: vec![candidate],
                        }),
                    );
                    continue;
                }
                Poll::Ready(gateway::Event::ConnectionConfigured {
                    client,
                    reference,
                    local_sdp: gateway_rtc_session_description,
                }) => {
                    tracing::debug!(%client, %reference, "Connection is ready");

                    let _id = self.portal.send(
                        PHOENIX_TOPIC,
                        EgressMessages::ConnectionReady(ConnectionReady {
                            reference,
                            gateway_rtc_session_description,
                        }),
                    );
                }
                Poll::Pending => {}
            }

            if self.print_stats_timer.poll_tick(cx).is_ready() {
                tracing::debug!(target: "tunnel_state", stats = ?self.tunnel.stats());
                continue;
            }

            return Poll::Pending;
        }
    }
}
