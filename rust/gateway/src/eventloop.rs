use crate::messages::{
    AllowAccess, BroadcastClientIceCandidates, ClientIceCandidates, ConnectionReady,
    EgressMessages, IngressMessages,
};
use crate::CallbackHandler;
use anyhow::{anyhow, Result};
use connlib_shared::messages::{ClientId, GatewayResponse};
use connlib_shared::Error;
use firezone_tunnel::{Event, GatewayState, Tunnel};
use std::convert::Infallible;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

pub const PHOENIX_TOPIC: &str = "gateway";

pub struct Eventloop {
    tunnel: Arc<Tunnel<CallbackHandler, GatewayState>>,
    portal: tokio::sync::mpsc::Receiver<IngressMessages>,
    portal_sender: tokio::sync::mpsc::Sender<EgressMessages>,

    // TODO: Strongly type request reference (currently `String`)
    connection_request_tasks:
        futures_bounded::FuturesMap<(ClientId, String), Result<GatewayResponse, Error>>,
    add_ice_candidate_tasks: futures_bounded::FuturesSet<Result<(), Error>>,

    print_stats_timer: tokio::time::Interval,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: Arc<Tunnel<CallbackHandler, GatewayState>>,
        portal: tokio::sync::mpsc::Receiver<IngressMessages>,
        portal_sender: tokio::sync::mpsc::Sender<EgressMessages>,
    ) -> Self {
        Self {
            tunnel,
            portal,
            portal_sender,

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
    #[tracing::instrument(name = "Eventloop::poll", skip_all, level = "debug")]
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<Infallible>> {
        loop {
            match self.tunnel.poll_next_event(cx)? {
                Poll::Ready(firezone_tunnel::Event::SignalIceCandidate {
                    conn_id: client,
                    candidate,
                }) => {
                    tracing::debug!(%client, %candidate, "Sending ICE candidate to client");

                    let sender = self.portal_sender.clone();
                    tokio::spawn(async move {
                        sender
                            .send(EgressMessages::BroadcastIceCandidates(
                                BroadcastClientIceCandidates {
                                    client_ids: vec![client],
                                    candidates: vec![candidate],
                                },
                            ))
                            .await
                    });
                    continue;
                }
                Poll::Ready(Event::ConnectionIntent { .. }) => {
                    unreachable!("Not used on the gateway, split the events!")
                }
                Poll::Ready(_) => continue,
                Poll::Pending => {}
            }

            match self.connection_request_tasks.poll_unpin(cx) {
                Poll::Ready(((client, reference), Ok(Ok(gateway_payload)))) => {
                    tracing::debug!(%client, %reference, "Connection is ready");

                    let sender = self.portal_sender.clone();
                    tokio::spawn(async move {
                        sender
                            .send(EgressMessages::ConnectionReady(ConnectionReady {
                                reference,
                                gateway_payload,
                            }))
                            .await
                    });

                    // TODO: If outbound request fails, cleanup connection.
                    continue;
                }
                Poll::Ready(((client, _), Ok(Err(e)))) => {
                    self.tunnel.cleanup_connection(client);
                    tracing::debug!(%client, "Connection request failed: {:#}", anyhow::Error::new(e));

                    continue;
                }
                Poll::Ready(((client, reference), Err(e))) => {
                    tracing::debug!(
                        %client,
                        %reference,
                        "Failed to establish connection: {:#}", anyhow::Error::new(e)
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
                    tracing::error!("Failed to add ICE candidate: {:#}", anyhow::Error::new(e));

                    continue;
                }
                Poll::Ready(Err(e)) => {
                    tracing::error!("Failed to add ICE candidate: {e}");
                    continue;
                }
                Poll::Pending => {}
            }

            match self.portal.poll_recv(cx) {
                Poll::Ready(Some(IngressMessages::RequestConnection(req))) => {
                    let tunnel = Arc::clone(&self.tunnel);

                    match self.connection_request_tasks.try_push(
                        (req.client.id, req.reference.clone()),
                        async move {
                            let conn = tunnel
                                .set_peer_connection_request(
                                    req.client.payload,
                                    req.client.peer.into(),
                                    req.relays,
                                    req.client.id,
                                    req.expires_at,
                                    req.resource,
                                )
                                .await?;
                            Ok(GatewayResponse::ConnectionAccepted(conn))
                        },
                    ) {
                        Err(futures_bounded::PushError::BeyondCapacity(_)) => {
                            tracing::warn!("Too many connections requests, dropping existing one");
                        }
                        Err(futures_bounded::PushError::Replaced(_)) => {
                            debug_assert!(false, "Received a 2nd connection requested with the same reference from the same client");
                        }
                        Ok(()) => {}
                    };
                    continue;
                }
                Poll::Ready(Some(IngressMessages::AllowAccess(AllowAccess {
                    client_id,
                    resource,
                    expires_at,
                    payload,
                    reference,
                }))) => {
                    tracing::debug!(client = %client_id, resource = %resource.id(), expires = ?expires_at.map(|e| e.to_rfc3339()), "Allowing access to resource");

                    let tunnel = Arc::clone(&self.tunnel);
                    let sender = self.portal_sender.clone();
                    tokio::spawn(async move {
                        if let Some(res) = tunnel
                            .allow_access(resource, client_id, expires_at, payload)
                            .await
                        {
                            if let Err(e) = sender
                                .send(EgressMessages::ConnectionReady(ConnectionReady {
                                    reference,
                                    gateway_payload: GatewayResponse::ResourceAccepted(res),
                                }))
                                .await
                            {
                                tracing::warn!("Error while sending gateway response: {e:#?}");
                            }
                        }
                    });
                    continue;
                }
                Poll::Ready(Some(IngressMessages::IceCandidates(ClientIceCandidates {
                    client_id,
                    candidates,
                }))) => {
                    for candidate in candidates {
                        tracing::debug!(client = %client_id, %candidate, "Adding ICE candidate from client");

                        let tunnel = Arc::clone(&self.tunnel);
                        if self
                            .add_ice_candidate_tasks
                            .try_push(async move {
                                tunnel.add_ice_candidate(client_id, candidate).await
                            })
                            .is_err()
                        {
                            tracing::debug!("Received too many ICE candidates, dropping some");
                        }
                    }
                    continue;
                }
                // if we dropped the sender it means that there was an unrecoverable error
                Poll::Ready(None) => {
                    return Poll::Ready(Err(anyhow!("portal connection completely dropped")));
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
