use crate::messages::{
    AllowAccess, ClientIceCandidates, ClientsIceCandidates, ConnectionReady, EgressMessages,
    IngressMessages, RejectAccess, RequestConnection,
};
use crate::CallbackHandler;
use anyhow::Result;
use boringtun::x25519::PublicKey;
use connlib_shared::messages::RelaysPresence;
use connlib_shared::{
    messages::{GatewayResponse, ResourceAccepted},
    DomainName,
};
#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use either::Either;
use firezone_tunnel::GatewayTunnel;
use futures_bounded::Timeout;
use ip_network::IpNetwork;
use phoenix_channel::PhoenixChannel;
use std::collections::HashSet;
use std::convert::Infallible;
use std::task::{Context, Poll};
use std::time::Duration;

pub const PHOENIX_TOPIC: &str = "gateway";

pub struct Eventloop {
    tunnel: GatewayTunnel<CallbackHandler>,
    portal: PhoenixChannel<(), IngressMessages, ()>,

    resolve_tasks:
        futures_bounded::FuturesTupleSet<Vec<IpNetwork>, Either<RequestConnection, AllowAccess>>,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: GatewayTunnel<CallbackHandler>,
        portal: PhoenixChannel<(), IngressMessages, ()>,
    ) -> Self {
        Self {
            tunnel,
            portal,
            resolve_tasks: futures_bounded::FuturesTupleSet::new(Duration::from_secs(5), 100),
        }
    }
}

impl Eventloop {
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<Infallible>> {
        loop {
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

            match self.resolve_tasks.poll_unpin(cx) {
                Poll::Ready((result, Either::Left(req))) => {
                    self.accept_connection(result, req);
                    continue;
                }
                Poll::Ready((result, Either::Right(req))) => {
                    self.allow_access(result, req);
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

    fn handle_tunnel_event(&mut self, event: firezone_tunnel::GatewayEvent) {
        match event {
            firezone_tunnel::GatewayEvent::NewIceCandidate {
                conn_id: client,
                candidate,
            } => {
                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::BroadcastIceCandidates(ClientsIceCandidates {
                        client_ids: vec![client],
                        candidates: vec![candidate],
                    }),
                );
            }
            firezone_tunnel::GatewayEvent::InvalidIceCandidate {
                conn_id: client,
                candidate,
            } => {
                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::BroadcastInvalidatedIceCandidates(ClientsIceCandidates {
                        client_ids: vec![client],
                        candidates: vec![candidate],
                    }),
                );
            }
        }
    }

    fn handle_portal_event(&mut self, event: phoenix_channel::Event<IngressMessages, ()>) {
        match event {
            phoenix_channel::Event::InboundMessage {
                msg: IngressMessages::RequestConnection(req),
                ..
            } => {
                if self
                    .resolve_tasks
                    .try_push(
                        resolve(req.client.payload.domain.clone()),
                        Either::Left(req),
                    )
                    .is_err()
                {
                    tracing::warn!("Too many connections requests, dropping existing one");
                };
            }
            phoenix_channel::Event::InboundMessage {
                msg: IngressMessages::AllowAccess(req),
                ..
            } => {
                if self
                    .resolve_tasks
                    .try_push(resolve(req.payload.clone()), Either::Right(req))
                    .is_err()
                {
                    tracing::warn!("Too many allow access requests, dropping existing one");
                };
            }
            phoenix_channel::Event::InboundMessage {
                msg:
                    IngressMessages::IceCandidates(ClientIceCandidates {
                        client_id,
                        candidates,
                    }),
                ..
            } => {
                for candidate in candidates {
                    self.tunnel.add_ice_candidate(client_id, candidate);
                }
            }
            phoenix_channel::Event::InboundMessage {
                msg:
                    IngressMessages::InvalidateIceCandidates(ClientIceCandidates {
                        client_id,
                        candidates,
                    }),
                ..
            } => {
                for candidate in candidates {
                    self.tunnel.remove_ice_candidate(client_id, candidate);
                }
            }
            phoenix_channel::Event::InboundMessage {
                msg:
                    IngressMessages::RejectAccess(RejectAccess {
                        client_id,
                        resource_id,
                    }),
                ..
            } => {
                self.tunnel.remove_access(&client_id, &resource_id);
            }
            phoenix_channel::Event::InboundMessage {
                msg:
                    IngressMessages::RelaysPresence(RelaysPresence {
                        disconnected_ids,
                        connected,
                    }),
                ..
            } => self
                .tunnel
                .update_relays(HashSet::from_iter(disconnected_ids), connected),
            phoenix_channel::Event::InboundMessage {
                msg: IngressMessages::Init(_),
                ..
            } => {
                // TODO: Handle `init` message during operation.
            }
            phoenix_channel::Event::InboundMessage {
                msg: IngressMessages::ResourceUpdated(resource_description),
                ..
            } => {
                self.tunnel.update_resource(resource_description);
            }
            phoenix_channel::Event::ErrorResponse { topic, req_id, res } => {
                tracing::warn!(%topic, %req_id, "Request failed: {res:?}");
            }
            phoenix_channel::Event::Closed => {
                unimplemented!("Gateway never actively closes the portal connection")
            }
            phoenix_channel::Event::SuccessResponse { res: (), .. }
            | phoenix_channel::Event::HeartbeatSent
            | phoenix_channel::Event::JoinedRoom { .. } => {}
        }
    }

    pub fn accept_connection(
        &mut self,
        result: Result<Vec<IpNetwork>, Timeout>,
        req: RequestConnection,
    ) {
        let addresses = result
            .inspect_err(|e| tracing::debug!(client = %req.client.id, reference = %req.reference, "DNS resolution timed out as part of connection request: {e}"))
            .unwrap_or_default();

        match self.tunnel.accept(
            req.client.id,
            req.client.peer.preshared_key,
            req.client.payload.ice_parameters,
            PublicKey::from(req.client.peer.public_key.0),
            req.client.peer.ipv4,
            req.client.peer.ipv6,
            req.relays,
            req.client.payload.domain,
            req.expires_at,
            req.resource.into_resolved(addresses),
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
            }
            Err(e) => {
                let client = req.client.id;

                self.tunnel.cleanup_connection(&client);
                tracing::debug!(%client, "Connection request failed: {:#}", anyhow::Error::new(e));
            }
        }
    }

    pub fn allow_access(&mut self, result: Result<Vec<IpNetwork>, Timeout>, req: AllowAccess) {
        let addresses = result
            .inspect_err(|e| tracing::debug!(client = %req.client_id, reference = %req.reference, "DNS resolution timed out as part of allow access request: {e}"))
            .unwrap_or_default();

        let maybe_domain_response = self.tunnel.allow_access(
            req.resource.into_resolved(addresses),
            req.client_id,
            req.expires_at,
            req.payload,
        );

        if let Some(domain_response) = maybe_domain_response {
            self.portal.send(
                PHOENIX_TOPIC,
                EgressMessages::ConnectionReady(ConnectionReady {
                    reference: req.reference,
                    gateway_payload: GatewayResponse::ResourceAccepted(ResourceAccepted {
                        domain_response,
                    }),
                }),
            );
        }
    }
}

async fn resolve(domain: Option<DomainName>) -> Vec<IpNetwork> {
    let Some(domain) = domain.clone() else {
        return vec![];
    };

    let dname = domain.to_string();

    match tokio::task::spawn_blocking(move || resolve_addresses(&dname)).await {
        Ok(Ok(addresses)) => addresses,
        Ok(Err(e)) => {
            tracing::warn!("Failed to resolve '{domain}': {e}");

            vec![]
        }
        Err(e) => {
            tracing::warn!("Failed to resolve '{domain}': {e}");

            vec![]
        }
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
