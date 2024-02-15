use crate::messages::{
    AllowAccess, BroadcastClientIceCandidates, ClientIceCandidates, ConnectionReady,
    EgressMessages, IngressMessages,
};
use crate::CallbackHandler;
use anyhow::{anyhow, Result};
use connlib_shared::messages::{
    ClientId, DomainResponse, GatewayResponse, ResourceAccepted, ResourceDescription,
};
use connlib_shared::Error;
use firezone_tunnel::{Event, GatewayState, ResolvedResourceDescriptionDns, Tunnel};
use ip_network::IpNetwork;
use phoenix_channel::PhoenixChannel;
use std::convert::Infallible;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

pub const PHOENIX_TOPIC: &str = "gateway";

pub struct Eventloop {
    tunnel: Arc<Tunnel<CallbackHandler, GatewayState>>,
    portal: PhoenixChannel<(), IngressMessages, EgressMessages>,

    // TODO: Strongly type request reference (currently `String`)
    connection_request_tasks:
        futures_bounded::FuturesMap<(ClientId, String), Result<GatewayResponse, Error>>,
    add_ice_candidate_tasks: futures_bounded::FuturesSet<Result<(), Error>>,
    allow_access_tasks: futures_bounded::FuturesMap<String, Option<DomainResponse>>,

    print_stats_timer: tokio::time::Interval,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: Arc<Tunnel<CallbackHandler, GatewayState>>,
        portal: PhoenixChannel<(), IngressMessages, EgressMessages>,
    ) -> Self {
        Self {
            tunnel,
            portal,

            // TODO: Pick sane values for timeouts and size.
            connection_request_tasks: futures_bounded::FuturesMap::new(
                Duration::from_secs(60),
                100,
            ),
            add_ice_candidate_tasks: futures_bounded::FuturesSet::new(Duration::from_secs(60), 100),
            print_stats_timer: tokio::time::interval(Duration::from_secs(10)),
            allow_access_tasks: futures_bounded::FuturesMap::new(Duration::from_secs(60), 100),
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

                    self.portal.send(
                        PHOENIX_TOPIC,
                        EgressMessages::BroadcastIceCandidates(BroadcastClientIceCandidates {
                            client_ids: vec![client],
                            candidates: vec![candidate],
                        }),
                    );

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

                    self.portal.send(
                        PHOENIX_TOPIC,
                        EgressMessages::ConnectionReady(ConnectionReady {
                            reference,
                            gateway_payload,
                        }),
                    );

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

            match self.allow_access_tasks.poll_unpin(cx) {
                Poll::Ready((reference, Ok(Some(domain_response)))) => {
                    self.portal.send(
                        PHOENIX_TOPIC,
                        EgressMessages::ConnectionReady(ConnectionReady {
                            reference,
                            gateway_payload: GatewayResponse::ResourceAccepted(ResourceAccepted {
                                domain_response,
                            }),
                        }),
                    );
                    continue;
                }
                Poll::Ready((_, Ok(None))) => {
                    continue;
                }
                Poll::Ready((reference, Err(e))) => {
                    tracing::debug!(
                        %reference,
                        "Failed to allow access: {:#}", anyhow::Error::new(e)
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

            match self.portal.poll(cx)? {
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg: IngressMessages::RequestConnection(req),
                    ..
                }) => {
                    let tunnel = Arc::clone(&self.tunnel);

                    let connection_request = async move {
                        let resource = resolve_resource_description(req.resource).await?;

                        let conn = tunnel
                            .set_peer_connection_request(
                                req.client.payload.ice_parameters,
                                req.client.peer.into(),
                                req.relays,
                                req.client.id,
                                req.client.payload.domain,
                                req.expires_at,
                                resource,
                            )
                            .await?;
                        Ok(GatewayResponse::ConnectionAccepted(conn))
                    };

                    match self
                        .connection_request_tasks
                        .try_push((req.client.id, req.reference.clone()), connection_request)
                    {
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
                    tracing::debug!(client = %client_id, resource = %resource.id(), expires = ?expires_at.map(|e| e.to_rfc3339()), "Allowing access to resource");

                    let tunnel = Arc::clone(&self.tunnel);

                    let allow_access = async move {
                        let resource = resolve_resource_description(resource).await.ok()?;

                        tunnel.allow_access(resource, client_id, expires_at, payload)
                    };

                    if self
                        .allow_access_tasks
                        .try_push(reference, allow_access)
                        .is_err()
                    {
                        tracing::warn!("Too many allow access requests, dropping existing one");
                    }
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
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg: IngressMessages::Init(_),
                    ..
                }) => {
                    // TODO: Handle `init` message during operation.
                    continue;
                }
                Poll::Ready(phoenix_channel::Event::Disconnect(reason)) => {
                    return Poll::Ready(Err(anyhow!("Disconnected by portal: {reason}")));
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

async fn resolve_resource_description(
    resource: ResourceDescription,
) -> io::Result<ResourceDescription<ResolvedResourceDescriptionDns>> {
    match resource {
        ResourceDescription::Dns(dns) => {
            let addresses = tokio::task::spawn_blocking({
                let domain = dns.address.clone();

                move || resolve_addresses(&domain)
            })
            .await??;

            Ok(ResourceDescription::Dns(ResolvedResourceDescriptionDns {
                id: dns.id,
                domain: dns.address,
                name: dns.name,
                addresses,
            }))
        }
        ResourceDescription::Cidr(cdir) => Ok(ResourceDescription::Cidr(cdir)),
    }
}

#[cfg(target_os = "windows")]
fn resolve_addresses(_: &str) -> std::io::Result<Vec<IpNetwork>> {
    unimplemented!()
}

#[cfg(not(target_os = "windows"))]
fn resolve_addresses(addr: &str) -> std::io::Result<Vec<IpNetwork>> {
    use libc::{AF_INET, AF_INET6};
    let addr_v4: std::io::Result<Vec<_>> = resolve_address_family(addr, AF_INET)
        .map_err(|e| e.into())
        .and_then(|a| a.collect());
    let addr_v6: std::io::Result<Vec<_>> = resolve_address_family(addr, AF_INET6)
        .map_err(|e| e.into())
        .and_then(|a| a.collect());
    match (addr_v4, addr_v6) {
        (Ok(v4), Ok(v6)) => Ok(v6
            .iter()
            .map(|a| a.sockaddr.ip().into())
            .chain(v4.iter().map(|a| a.sockaddr.ip().into()))
            .collect()),
        (Ok(v4), Err(_)) => Ok(v4.iter().map(|a| a.sockaddr.ip().into()).collect()),
        (Err(_), Ok(v6)) => Ok(v6.iter().map(|a| a.sockaddr.ip().into()).collect()),
        (Err(e), Err(_)) => Err(e),
    }
}

#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use std::io;

#[cfg(not(target_os = "windows"))]
fn resolve_address_family(
    addr: &str,
    family: i32,
) -> std::result::Result<AddrInfoIter, LookupError> {
    use libc::SOCK_STREAM;

    dns_lookup::getaddrinfo(
        Some(addr),
        None,
        Some(AddrInfoHints {
            socktype: SOCK_STREAM,
            address: family,
            ..Default::default()
        }),
    )
}
