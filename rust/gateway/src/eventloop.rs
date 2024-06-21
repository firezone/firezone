use crate::messages::{
    AllowAccess, ClientIceCandidates, ClientsIceCandidates, ConnectionReady, EgressMessages,
    IngressMessages, RejectAccess, RequestConnection,
};
use crate::CallbackHandler;
use anyhow::Result;
use boringtun::x25519::PublicKey;
use connlib_shared::messages::{
    ClientId, ConnectionAccepted, RelaysPresence, ResourceAccepted, ResourceId,
};
use connlib_shared::{messages::GatewayResponse, DomainName};
#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use firezone_tunnel::GatewayTunnel;
use futures_bounded::Timeout;
use phoenix_channel::PhoenixChannel;
use std::collections::HashSet;
use std::convert::Infallible;
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

    resolve_tasks: futures_bounded::FuturesTupleSet<Vec<IpAddr>, ResolveTrigger>,
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
        result: Result<Vec<IpAddr>, Timeout>,
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
            req.client.payload.domain.as_ref().map(|r| r.as_tuple()),
            req.expires_at,
            req.resource.into_resolved(addresses.clone()),
        ) {
            Ok(accepted) => {
                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::ConnectionReady(ConnectionReady {
                        reference: req.reference,
                        gateway_payload: GatewayResponse::ConnectionAccepted(ConnectionAccepted {
                            ice_parameters: accepted,
                            domain_response: req.client.payload.domain.map(|r| {
                                connlib_shared::messages::DomainResponse {
                                    domain: r.name(),
                                    address: addresses,
                                }
                            }),
                        }),
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

    pub fn allow_access(&mut self, result: Result<Vec<IpAddr>, Timeout>, req: AllowAccess) {
        let addresses = result
            .inspect_err(|e| tracing::debug!(client = %req.client_id, reference = %req.reference, "DNS resolution timed out as part of allow access request: {e}"))
            .unwrap_or_default();

        if let (Ok(()), Some(resolve_request)) = (
            self.tunnel.allow_access(
                req.resource.into_resolved(addresses.clone()),
                req.client_id,
                req.expires_at,
                req.payload.as_ref().map(|r| r.as_tuple()),
            ),
            req.payload,
        ) {
            self.portal.send(
                PHOENIX_TOPIC,
                EgressMessages::ConnectionReady(ConnectionReady {
                    reference: req.reference,
                    gateway_payload: GatewayResponse::ResourceAccepted(ResourceAccepted {
                        domain_response: connlib_shared::messages::DomainResponse {
                            domain: resolve_request.name(),
                            address: addresses,
                        },
                    }),
                }),
            );
        }
    }

    pub fn refresh_translation(
        &mut self,
        result: Result<Vec<IpAddr>, Timeout>,
        conn_id: ClientId,
        resource_id: ResourceId,
        name: DomainName,
    ) {
        let addresses = result
            .inspect_err(|e| tracing::debug!(%conn_id, "DNS resolution timed out as part of allow access request: {e}"))
            .unwrap_or_default();

        self.tunnel
            .refresh_translation(conn_id, resource_id, name, addresses);
    }
}

async fn resolve(domain: Option<DomainName>) -> Vec<IpAddr> {
    let Some(domain) = domain.clone() else {
        return vec![];
    };

    let dname = domain.to_string();

    tokio::task::spawn_blocking(move || resolve_addresses(&dname))
        .await
        .inspect_err(|e| tracing::warn!(%domain, "DNS resolution task failed: {e}"))
        .unwrap_or_default()
}

#[cfg(target_os = "windows")]
fn resolve_addresses(_: &str) -> Vec<IpAddr> {
    unimplemented!()
}

#[cfg(not(target_os = "windows"))]
fn resolve_addresses(domain: &str) -> Vec<IpAddr> {
    use libc::{AF_INET, AF_INET6};

    let addr_v4 = resolve_address_family(domain, AF_INET)
        .inspect_err(|e| tracing::warn!(%domain, "Failed to resolve A records: {e:?}")); // FIXME: Upstream an fmt::Display impl for LookupError.
    let addr_v6 = resolve_address_family(domain, AF_INET6)
        .inspect_err(|e| tracing::warn!(%domain, "Failed to resolve AAAA records: {e:?}"));

    addr_v4
        .into_iter()
        .chain(addr_v6)
        .flatten()
        .filter_map(|result| match result {
            Ok(addr) => Some(addr.sockaddr.ip()),
            Err(e) => {
                tracing::warn!("Failed to parse DNS record: {e}");
                None
            }
        })
        .filter(|ip| {
            if is_dns64_address(ip) {
                tracing::info!(%domain, %ip, "Ignoring DNS64 address record");
                return false;
            }

            true
        })
        .collect()
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

/// Checks if the given IP is a synthesized DNS64 IPv6 address.
///
/// DNS64 IPv6 addresses are within the `0064:ff9b/96` subnet.
///
/// See <https://en.wikipedia.org/wiki/IPv6_transition_mechanism#DNS64> for details.
fn is_dns64_address(ip: &IpAddr) -> bool {
    let IpAddr::V6(v6) = ip else {
        return false;
    };

    matches!(
        v6.octets(),
        [00, 0x64, 0xff, 0x9b, _, _, _, _, _, _, _, _, _, _, _, _]
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv6Addr;

    #[test]
    fn detects_dns64_addr() {
        assert!(is_dns64_address(&"64:ff9b::8c52:7004".parse().unwrap()))
    }

    #[test]
    fn ignores_non_dns64_addr() {
        assert!(!is_dns64_address(&IpAddr::V6(Ipv6Addr::LOCALHOST)))
    }
}
