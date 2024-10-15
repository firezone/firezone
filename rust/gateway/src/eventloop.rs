use anyhow::Result;
use boringtun::x25519::PublicKey;
use connlib_model::DomainName;
use connlib_model::{ClientId, ResourceId};
#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use firezone_tunnel::messages::{
    gateway::{
        AllowAccess, ClientIceCandidates, ClientsIceCandidates, ConnectionReady, EgressMessages,
        IngressMessages, RejectAccess, RequestConnection,
    },
    ConnectionAccepted, GatewayResponse, Interface, RelaysPresence,
};
use firezone_tunnel::{DnsResourceNatEntry, GatewayTunnel};
use futures::channel::mpsc;
use futures_bounded::Timeout;
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use std::collections::BTreeSet;
use std::convert::Infallible;
use std::io;
use std::net::IpAddr;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

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
    tunnel: GatewayTunnel,
    portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
    tun_device_channel: mpsc::Sender<Interface>,

    resolve_tasks: futures_bounded::FuturesTupleSet<Vec<IpAddr>, ResolveTrigger>,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: GatewayTunnel,
        mut portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
        tun_device_channel: mpsc::Sender<Interface>,
    ) -> Self {
        portal.connect(PublicKeyParam(tunnel.public_key().to_bytes()));

        Self {
            tunnel,
            portal,
            resolve_tasks: futures_bounded::FuturesTupleSet::new(DNS_RESOLUTION_TIMEOUT, 100),
            tun_device_channel,
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
                Poll::Ready(Err(e)) if e.kind() == io::ErrorKind::WouldBlock => {
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
            firezone_tunnel::GatewayEvent::AddedIceCandidates {
                conn_id: client,
                candidates,
            } => {
                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::BroadcastIceCandidates(ClientsIceCandidates {
                        client_ids: vec![client],
                        candidates,
                    }),
                );
            }
            firezone_tunnel::GatewayEvent::RemovedIceCandidates {
                conn_id: client,
                candidates,
            } => {
                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::BroadcastInvalidatedIceCandidates(ClientsIceCandidates {
                        client_ids: vec![client],
                        candidates,
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
                        resolve(req.client.payload.domain.as_ref().map(|r| r.name.clone())),
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
                        resolve(req.payload.as_ref().map(|r| r.name.clone())),
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
                    self.tunnel
                        .state_mut()
                        .add_ice_candidate(client_id, candidate, Instant::now());
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
                    self.tunnel.state_mut().remove_ice_candidate(
                        client_id,
                        candidate,
                        Instant::now(),
                    );
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
                self.tunnel
                    .state_mut()
                    .remove_access(&client_id, &resource_id);
            }
            phoenix_channel::Event::InboundMessage {
                msg:
                    IngressMessages::RelaysPresence(RelaysPresence {
                        disconnected_ids,
                        connected,
                    }),
                ..
            } => self.tunnel.state_mut().update_relays(
                BTreeSet::from_iter(disconnected_ids),
                firezone_tunnel::turn(&connected),
                Instant::now(),
            ),
            phoenix_channel::Event::InboundMessage {
                msg: IngressMessages::Init(init),
                ..
            } => {
                self.tunnel.state_mut().update_relays(
                    BTreeSet::default(),
                    firezone_tunnel::turn(&init.relays),
                    Instant::now(),
                );

                // FIXME(tech-debt): Currently, the `Tunnel` creates the TUN device as part of `set_interface`.
                // For the gateway, it doesn't do anything else so in an ideal world, we would cause the side-effect out here and just pass an opaque `Device` to the `Tunnel`.
                // That requires more refactoring of other platforms, so for now, we need to rely on the `Tunnel` interface and cause the side-effect separately via the `TunDeviceManager`.
                if let Err(e) = self.tun_device_channel.try_send(init.interface) {
                    tracing::warn!("Failed to set interface: {e}");
                }
            }
            phoenix_channel::Event::InboundMessage {
                msg: IngressMessages::ResourceUpdated(resource_description),
                ..
            } => {
                self.tunnel
                    .state_mut()
                    .update_resource(resource_description);
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

        let answer = self.tunnel.state_mut().accept(
            req.client.id,
            req.client
                .payload
                .ice_parameters
                .into_snownet_offer(req.client.peer.preshared_key),
            PublicKey::from(req.client.peer.public_key.0),
            Instant::now(),
        );

        if let Err(e) = self.tunnel.state_mut().allow_access(
            req.client.id,
            req.client.peer.ipv4,
            req.client.peer.ipv6,
            req.expires_at,
            req.resource,
            req.client
                .payload
                .domain
                .map(|r| DnsResourceNatEntry::new(r, addresses)),
            Instant::now(),
        ) {
            let client = req.client.id;

            self.tunnel.state_mut().cleanup_connection(&client);
            tracing::debug!(%client, "Connection request failed: {e:#}");
            return;
        }

        self.portal.send(
            PHOENIX_TOPIC,
            EgressMessages::ConnectionReady(ConnectionReady {
                reference: req.reference,
                gateway_payload: GatewayResponse::ConnectionAccepted(ConnectionAccepted {
                    ice_parameters: answer,
                    domain_response: None,
                }),
            }),
        );
    }

    pub fn allow_access(&mut self, result: Result<Vec<IpAddr>, Timeout>, req: AllowAccess) {
        let addresses = result
            .inspect_err(|e| tracing::debug!(client = %req.client_id, reference = %req.reference, "DNS resolution timed out as part of allow access request: {e}"))
            .unwrap_or_default();

        if let Err(e) = self.tunnel.state_mut().allow_access(
            req.client_id,
            req.client_ipv4,
            req.client_ipv6,
            req.expires_at,
            req.resource,
            req.payload.map(|r| DnsResourceNatEntry::new(r, addresses)),
            Instant::now(),
        ) {
            tracing::warn!(client = %req.client_id, "Allow access request failed: {e:#}");
        };
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

        self.tunnel.state_mut().refresh_translation(
            conn_id,
            resource_id,
            name,
            addresses,
            Instant::now(),
        );
    }
}

async fn resolve(domain: Option<DomainName>) -> Vec<IpAddr> {
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
fn resolve_address_family(addr: &str, family: i32) -> Result<AddrInfoIter, LookupError> {
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
