use crate::control::ControlSignaler;
use crate::messages::{
    AllowAccess, BroadcastClientIceCandidates, ClientIceCandidates, ConnectionReady,
    EgressMessages, IngressMessages,
};
use crate::CallbackHandler;
use anyhow::Result;
use connlib_shared::messages::ClientId;
use connlib_shared::{Callbacks, Error};
use firezone_tunnel::Tunnel;
use phoenix_channel::PhoenixChannel;
use std::convert::Infallible;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::sync::mpsc;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

pub const PHOENIX_TOPIC: &str = "gateway";

pub struct Eventloop {
    tunnel: Arc<Tunnel<ControlSignaler, CallbackHandler>>,
    control_rx: mpsc::Receiver<BroadcastClientIceCandidates>,
    portal: PhoenixChannel<IngressMessages, ()>,

    // TODO: Strongly type request reference (currently `String`)
    connection_request_tasks:
        futures_bounded::FuturesMap<(ClientId, String), Result<RTCSessionDescription, Error>>,
    add_ice_candidate_tasks: futures_bounded::FuturesSet<Result<(), Error>>,

    print_stats_timer: tokio::time::Interval,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: Arc<Tunnel<ControlSignaler, CallbackHandler>>,
        control_rx: mpsc::Receiver<BroadcastClientIceCandidates>,
        portal: PhoenixChannel<IngressMessages, ()>,
    ) -> Self {
        Self {
            tunnel,
            control_rx,
            portal,

            // TODO: Pick sane values for timeouts and size.
            connection_request_tasks: futures_bounded::FuturesMap::new(
                Duration::from_secs(60),
                100,
            ),
            add_ice_candidate_tasks: futures_bounded::FuturesSet::new(Duration::from_secs(60), 100),
            print_stats_timer: tokio::time::interval(Duration::from_secs(10)),
        }
    }
}

impl Eventloop {
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<Infallible>> {
        loop {
            if let Poll::Ready(Some(ice_candidates)) = self.control_rx.poll_recv(cx) {
                let _id = self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::BroadcastIceCandidates(ice_candidates),
                );
                continue;
            }

            match self.connection_request_tasks.poll_unpin(cx) {
                Poll::Ready(((_, reference), Ok(Ok(gateway_rtc_session_description)))) => {
                    let _id = self.portal.send(
                        PHOENIX_TOPIC,
                        EgressMessages::ConnectionReady(ConnectionReady {
                            reference,
                            gateway_rtc_session_description,
                        }),
                    );

                    // TODO: If outbound request fails, cleanup connection.
                    continue;
                }
                Poll::Ready(((client, _), Ok(Err(e)))) => {
                    self.tunnel.cleanup_connection(client.into());
                    let _ = self.tunnel.callbacks().on_error(&e);
                    continue;
                }
                Poll::Ready(((client, reference), Err(e))) => {
                    tracing::debug!(
                        "Failed to establish connection {reference} from client {client:?}: {e}"
                    );
                    continue;
                }
                Poll::Pending => {}
            }

            match self.add_ice_candidate_tasks.poll_unpin(cx) {
                Poll::Ready(Ok(Ok(()))) => {
                    continue;
                }
                Poll::Ready(Ok(Err(e))) => {
                    tracing::error!(err = ?e,"add_ice_candidate");
                    let _ = self.tunnel.callbacks().on_error(&e);
                    continue;
                }
                Poll::Ready(Err(e)) => {
                    tracing::debug!("Failed to add ICE candidatee: {e}");
                    continue;
                }
                Poll::Pending => {}
            }

            match self.portal.poll(cx)? {
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg: IngressMessages::Init(_),
                    ..
                }) => {
                    debug_assert!(false, "Received init message during operation");
                }
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg: IngressMessages::RequestConnection(req),
                    ..
                }) => {
                    let tunnel = Arc::clone(&self.tunnel);

                    match self.connection_request_tasks.try_push(
                        (req.client.id, req.reference.clone()),
                        async move {
                            tunnel
                                .set_peer_connection_request(
                                    req.client.rtc_session_description,
                                    req.client.peer.into(),
                                    req.relays,
                                    req.client.id,
                                    req.expires_at,
                                    req.resource,
                                )
                                .await
                        },
                    ) {
                        Err(futures_bounded::PushError::BeyondCapacity(_)) => {
                            tracing::warn!("Too many connections requests, dropping existing one");
                        }
                        Err(futures_bounded::PushError::ReplacedFuture(_)) => {
                            debug_assert!(false, "Received a 2nd connection requested with the same reference from the same client");
                        }
                        Ok(()) => {}
                    };
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
                        let tunnel = Arc::clone(&self.tunnel);
                        if self
                            .add_ice_candidate_tasks
                            .try_push(async move {
                                tunnel.add_ice_candidate(client_id.into(), candidate).await
                            })
                            .is_err()
                        {
                            tracing::debug!("Received too many ICE candidates, dropping some");
                        }
                    }
                    continue;
                }
                _ => {}
            }

            if self.print_stats_timer.poll_tick(cx).is_ready() {
                tracing::debug!(target: "tunnel_state", stats = ?self.tunnel.stats());
                continue;
            }

            return Poll::Pending;
        }
    }
}
