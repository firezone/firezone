use crate::messages::{
    AllowAccess, ClientIceCandidates, ClientsIceCandidates, ConnectionReady, EgressMessages,
    IngressMessages, RejectAccess, RequestConnection, ResolveRequest,
};
use crate::CallbackHandler;
use anyhow::Result;
use boringtun::x25519::PublicKey;
use connlib_shared::messages::DomainResponse;
use connlib_shared::messages::{
    ClientId, ConnectionAccepted,
    {ConnectionFailedError, RelaysPresence, ResourceAccepted, ResourceId},
};
use connlib_shared::{messages::GatewayResponse, DomainName};
#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use firezone_tunnel::GatewayTunnel;
use futures_bounded::Timeout;
use phoenix_channel::PhoenixChannel;
use std::collections::HashSet;
use std::convert::Infallible;
use std::io;
use std::net::IpAddr;
use std::task::{Context, Poll};
use std::time::Duration;

pub const PHOENIX_TOPIC: &str = "gateway";

/// How long we allow a DNS resolution via `libc::get_addr_info`.
const DNS_RESOLUTION_TIMEOUT: Duration = Duration::from_secs(10);

// DNS resolution happens as part of every connection setup.
// For a connection to succeed, DNS resolution must be less than `snownet`'s handshake timeout.
static_assertions::const_assert!(
    DNS_RESOLUTION_TIMEOUT.as_secs() < snownet::HANDSHAKE_TIMEOUT.as_secs()
);

#[derive(Debug, Clone)]
enum ResolveTrigger {
    RequestConnection(RequestConnection),
    AllowAccess(AllowAccess),
    Refresh(DomainName, ClientId, ResourceId),
}

pub struct Eventloop {
    tunnel: GatewayTunnel<CallbackHandler>,
    portal: PhoenixChannel<(), IngressMessages, ()>,

    resolve_tasks: futures_bounded::FuturesTupleSet<io::Result<Vec<IpAddr>>, ResolveTrigger>,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: GatewayTunnel<CallbackHandler>,
        portal: PhoenixChannel<(), IngressMessages, ()>,
    ) -> Self {
        Self {
            tunnel,
            portal,
            resolve_tasks: futures_bounded::FuturesTupleSet::new(DNS_RESOLUTION_TIMEOUT, 100),
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
                Poll::Ready((result, ResolveTrigger::RequestConnection(req))) => {
                    self.accept_connection(result, req);
                    continue;
                }
                Poll::Ready((result, ResolveTrigger::AllowAccess(req))) => {
                    self.allow_access(result, req);
                    continue;
                }
                Poll::Ready((result, ResolveTrigger::Refresh(name, conn_id, resource_id))) => {
                    self.refresh_translation(result, conn_id, resource_id, name);
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
            firezone_tunnel::GatewayEvent::RefreshDns {
                name,
                conn_id,
                resource_id,
            } => {
                if self
                    .resolve_tasks
                    .try_push(
                        resolve(Some(name.clone())),
                        ResolveTrigger::Refresh(name, conn_id, resource_id),
                    )
                    .is_err()
                {
                    tracing::warn!("Too many dns resolution requests, dropping existing one");
                };
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
                        resolve(req.client.payload.domain.as_ref().map(|r| r.name())),
                        ResolveTrigger::RequestConnection(req),
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
                    .try_push(
                        resolve(req.payload.as_ref().map(|r| r.name())),
                        ResolveTrigger::AllowAccess(req),
                    )
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
        result: Result<io::Result<Vec<IpAddr>>, Timeout>,
        req: RequestConnection,
    ) {
        let addresses = match result {
            Ok(Ok(addresses)) => addresses,
            Ok(Err(e)) => {
                tracing::warn!(client = %req.client.id, reference = %req.reference, "DNS resolution failed as part of connection request: {e}");

                self.send_connection_reply(req.reference, ConnectionFailedError::Dns);
                return;
            }
            Err(e) => {
                tracing::warn!(client = %req.client.id, reference = %req.reference, "DNS resolution timed out as part of connection request: {e}");

                self.send_connection_reply(req.reference, ConnectionFailedError::Dns);
                return;
            }
        };

        let result = self.tunnel.accept(
            req.client.id,
            req.client.peer.preshared_key,
            req.client.payload.ice_parameters,
            PublicKey::from(req.client.peer.public_key.0),
            req.client.peer.ipv4,
            req.client.peer.ipv6,
            req.relays,
            req.client.payload.domain.as_ref().map(|r| r.as_tuple()),
            req.expires_at,
            req.resource.into_resolved(addresses.clone()),
        );

        let answer = match result {
            Ok(accepted) => accepted,
            Err(e) => {
                let client = req.client.id;

                self.tunnel.cleanup_connection(&client);

                tracing::warn!(%client, "Failed to accept connection: {e}");
                self.send_connection_reply(req.reference, ConnectionFailedError::AllowAccess);

                return;
            }
        };

        self.send_connection_reply(
            req.reference,
            ConnectionAccepted {
                ice_parameters: answer,
                domain_response: req.client.payload.domain.map(|r| DomainResponse {
                    domain: r.name(),
                    address: addresses,
                }),
            },
        );
    }

    /// Execute the [`AllowAccess`] request from the client.
    ///
    /// Note that we do **not** send [`ConnectionFailedError`]s back to the client.
    /// Clients don't distinguish between errors from `allow_access` and `connection_request` and thus always clean up the connection on any error.
    pub fn allow_access(
        &mut self,
        result: Result<io::Result<Vec<IpAddr>>, Timeout>,
        req: AllowAccess,
    ) {
        let addresses = match result {
            Ok(Ok(addresses)) => addresses,
            Ok(Err(e)) => {
                tracing::warn!(client = %req.client_id, reference = %req.reference, "DNS resolution failed as part of allow request: {e}");
                return;
            }
            Err(e) => {
                tracing::warn!(client = %req.client_id, reference = %req.reference, "DNS resolution timed out as part of allow request: {e}");
                return;
            }
        };

        let result = self.tunnel.allow_access(
            req.resource.into_resolved(addresses.clone()),
            req.client_id,
            req.expires_at,
            req.payload.as_ref().map(|r| r.as_tuple()),
        );

        match result {
            Ok(maybe_domain_response) => maybe_domain_response,
            Err(e) => {
                tracing::warn!(client = %req.client_id, "Failed to allow access: {e}");
                return;
            }
        };

        match (result, req.payload) {
            (Ok(()), Some(ResolveRequest::ReturnResponse(domain))) => {
                self.send_connection_reply(
                    req.reference,
                    ResourceAccepted {
                        domain_response: DomainResponse {
                            domain,
                            address: addresses,
                        },
                    },
                );
            }
            (
                Ok(_) | Err(_),
                Some(ResolveRequest::ReturnResponse(_) | ResolveRequest::MapResponse { .. }) | None,
            ) => {}
        }
    }

    fn send_connection_reply(&mut self, req_ref: String, result: impl Into<GatewayResponse>) {
        self.portal.send(
            PHOENIX_TOPIC,
            EgressMessages::ConnectionReady(ConnectionReady {
                reference: req_ref,
                gateway_payload: result.into(),
            }),
        );
    }

    pub fn refresh_translation(
        &mut self,
        result: Result<io::Result<Vec<IpAddr>>, Timeout>,
        conn_id: ClientId,
        resource_id: ResourceId,
        name: DomainName,
    ) {
        let addresses = match result {
            Ok(Ok(addresses)) => addresses,
            Ok(Err(e)) => {
                tracing::warn!(client = %conn_id, "DNS resolution failed as part of refreshing DNS: {e}");
                return;
            }
            Err(e) => {
                tracing::warn!(client = %conn_id, "DNS resolution timed as part of refreshing DNS: {e}");
                return;
            }
        };

        self.tunnel
            .refresh_translation(conn_id, resource_id, name, addresses);
    }
}

async fn resolve(domain: Option<DomainName>) -> io::Result<Vec<IpAddr>> {
    let Some(domain) = domain.clone() else {
        return Ok(vec![]);
    };

    let dname = domain.to_string();

    match tokio::task::spawn_blocking(move || resolve_addresses(&dname)).await {
        Ok(result) => result,
        Err(e) => Err(io::Error::new(io::ErrorKind::Interrupted, e)),
    }
}

#[cfg(target_os = "windows")]
fn resolve_addresses(_: &str) -> std::io::Result<Vec<IpAddr>> {
    unimplemented!()
}

#[cfg(not(target_os = "windows"))]
fn resolve_addresses(addr: &str) -> std::io::Result<Vec<IpAddr>> {
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
            .map(|a| a.sockaddr.ip())
            .chain(v4.iter().map(|a| a.sockaddr.ip()))
            .collect()),
        (Ok(v4), Err(_)) => Ok(v4.iter().map(|a| a.sockaddr.ip()).collect()),
        (Err(_), Ok(v6)) => Ok(v6.iter().map(|a| a.sockaddr.ip()).collect()),
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
