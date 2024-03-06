use crate::messages::{
    AllowAccess, BroadcastClientIceCandidates, ClientIceCandidates, ConnectionReady,
    EgressMessages, IngressMessages, RejectAccess, RequestConnection,
};
use crate::CallbackHandler;
use anyhow::{anyhow, bail, Result};
use boringtun::x25519::PublicKey;
use connlib_shared::{
    messages::{GatewayResponse, ResourceAccepted, ResourceDescription},
    Dname,
};
#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use either::Either;
use firezone_tunnel::{Event, GatewayTunnel, ResolvedResourceDescriptionDns};
use ip_network::IpNetwork;
use phoenix_channel::PhoenixChannel;
use std::convert::Infallible;
use std::task::{Context, Poll};
use std::time::Duration;

pub const PHOENIX_TOPIC: &str = "gateway";

pub struct Eventloop {
    tunnel: GatewayTunnel<CallbackHandler>,
    portal: PhoenixChannel<(), IngressMessages, EgressMessages>,

    resolve_tasks: futures_bounded::FuturesTupleSet<
        Result<ResourceDescription<ResolvedResourceDescriptionDns>>,
        Either<RequestConnection, AllowAccess>,
    >,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: GatewayTunnel<CallbackHandler>,
        portal: PhoenixChannel<(), IngressMessages, EgressMessages>,
    ) -> Self {
        Self {
            tunnel,
            portal,
            resolve_tasks: futures_bounded::FuturesTupleSet::new(Duration::from_secs(60), 100),
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

            match self.resolve_tasks.poll_unpin(cx) {
                Poll::Ready((Ok(Ok(resource)), Either::Left(req))) => {
                    let ips = req.client.peer.ips();

                    match self.tunnel.accept(
                        req.client.id,
                        req.client.peer.preshared_key,
                        req.client.payload.ice_parameters,
                        PublicKey::from(req.client.peer.public_key.0),
                        ips,
                        req.relays,
                        req.client.payload.domain,
                        req.expires_at,
                        resource,
                    ) {
                        Ok(accepted) => {
                            self.portal.send(
                                PHOENIX_TOPIC,
                                EgressMessages::ConnectionReady(ConnectionReady {
                                    reference: req.reference,
                                    gateway_payload: GatewayResponse::ConnectionAccepted(accepted),
                                }),
                            );

                            // TODO: If outbound request fails, cleanup connection.
                            continue;
                        }
                        Err(e) => {
                            let client = req.client.id;

                            self.tunnel.cleanup_connection(&client);
                            tracing::debug!(%client, "Connection request failed: {:#}", anyhow::Error::new(e));

                            continue;
                        }
                    }
                }
                Poll::Ready((Ok(Ok(resource)), Either::Right(req))) => {
                    let maybe_domain_response = self.tunnel.allow_access(
                        resource,
                        req.client_id,
                        req.expires_at,
                        req.payload,
                    );

                    if let Some(domain_response) = maybe_domain_response {
                        self.portal.send(
                            PHOENIX_TOPIC,
                            EgressMessages::ConnectionReady(ConnectionReady {
                                reference: req.reference,
                                gateway_payload: GatewayResponse::ResourceAccepted(
                                    ResourceAccepted { domain_response },
                                ),
                            }),
                        );
                        continue;
                    }
                }
                Poll::Ready((Ok(Err(dns_error)), Either::Left(req))) => {
                    tracing::debug!(client = %req.client.id, reference = %req.reference, "Failed to resolve domains as part of connection request: {dns_error}");
                    continue;
                }
                Poll::Ready((Ok(Err(dns_error)), Either::Right(req))) => {
                    tracing::debug!(client = %req.client_id, reference = %req.reference, "Failed to resolve domains as part of allow access request: {dns_error}");
                    continue;
                }
                Poll::Ready((Err(dns_timeout), Either::Left(req))) => {
                    tracing::debug!(client = %req.client.id, reference = %req.reference, "DNS resolution timed out as part of connection request: {dns_timeout}");
                    continue;
                }
                Poll::Ready((Err(dns_timeout), Either::Right(req))) => {
                    tracing::debug!(client = %req.client_id, reference = %req.reference, "DNS resolution timed out as part of allow access request: {dns_timeout}");
                    continue;
                }
                Poll::Pending => {}
            }
            match self.portal.poll(cx)? {
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg: IngressMessages::RequestConnection(req),
                    ..
                }) => {
                    if self
                        .resolve_tasks
                        .try_push(
                            resolve_resource_description(
                                req.resource.clone(),
                                req.client.payload.domain.clone(),
                            ),
                            Either::Left(req),
                        )
                        .is_err()
                    {
                        tracing::warn!("Too many connections requests, dropping existing one");
                    };

                    continue;
                }
                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg: IngressMessages::AllowAccess(req),
                    ..
                }) => {
                    if self
                        .resolve_tasks
                        .try_push(
                            resolve_resource_description(req.resource.clone(), req.payload.clone()),
                            Either::Right(req),
                        )
                        .is_err()
                    {
                        tracing::warn!("Too many allow access requests, dropping existing one");
                    };

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

                        self.tunnel.add_ice_candidate(client_id, candidate);
                    }
                    continue;
                }

                Poll::Ready(phoenix_channel::Event::InboundMessage {
                    msg:
                        IngressMessages::RejectAccess(RejectAccess {
                            client_id,
                            resource_id,
                        }),
                    ..
                }) => {
                    tracing::debug!(client = %client_id, resource = %resource_id, "Access removed");

                    self.tunnel.remove_access(&client_id, &resource_id);
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

            return Poll::Pending;
        }
    }
}

async fn resolve_resource_description(
    resource: ResourceDescription,
    domain: Option<Dname>,
) -> Result<ResourceDescription<ResolvedResourceDescriptionDns>> {
    match resource {
        ResourceDescription::Dns(dns) => {
            let Some(domain) = domain.clone() else {
                debug_assert!(
                    false,
                    "We should never get a DNS resource access request without the subdomain"
                );
                bail!("Protocol error: Request for DNS resource without the subdomain being tried to access.")
            };

            let addresses =
                tokio::task::spawn_blocking(move || resolve_addresses(&domain.to_string()))
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
