use anyhow::Result;
use boringtun::x25519::PublicKey;
use connlib_model::DomainName;
use connlib_model::{ClientId, ResourceId};
#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use firezone_tunnel::messages::gateway::{
    ClientIceCandidates, ClientsIceCandidates, EgressMessages, IngressMessages, RejectAccess,
};
use firezone_tunnel::messages::{Interface, RelaysPresence};
use firezone_tunnel::{GatewayTunnel, PendingSetupNatRequest};
use futures::channel::mpsc;
use futures_bounded::Timeout;
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use std::collections::BTreeSet;
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
    Refresh(DomainName, ClientId, ResourceId),
    SetupNat(PendingSetupNatRequest),
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
            resolve_tasks: futures_bounded::FuturesTupleSet::new(DNS_RESOLUTION_TIMEOUT, 1000),
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
                Poll::Ready(Err(e)) => {
                    tracing::warn!("Tunnel error: {e}");
                    continue;
                }
                Poll::Pending => {}
            }

            match self.resolve_tasks.poll_unpin(cx) {
                Poll::Ready((result, ResolveTrigger::Refresh(name, conn_id, resource_id))) => {
                    self.refresh_translation(result, conn_id, resource_id, name);
                    continue;
                }
                Poll::Ready((result, ResolveTrigger::SetupNat(request))) => {
                    let addresses = result
                        .inspect_err(|e| {
                            tracing::debug!(
                                "DNS resolution timed out as part of setup NAT request: {e}"
                            )
                        })
                        .unwrap_or_default();

                    self.tunnel.setup_dns_resource_nat(request, addresses);

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
            firezone_tunnel::GatewayEvent::ResolveDns(setup_nat) => {
                if self
                    .resolve_tasks
                    .try_push(
                        resolve(Some(setup_nat.domain().clone())),
                        ResolveTrigger::SetupNat(setup_nat),
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
                msg:
                    IngressMessages::AuthorizeFlow {
                        resource,
                        expires_at,
                        client_id,
                        client_key,
                        client_ipv4,
                        client_ipv6,
                        preshared_key,
                        client_ice,
                        gateway_ice,
                        reference,
                    },
                ..
            } => {
                self.tunnel.authorize_flow(
                    client_id,
                    PublicKey::from(client_key.0),
                    preshared_key,
                    client_ice,
                    gateway_ice,
                    client_ipv4,
                    client_ipv6,
                    expires_at,
                    resource,
                );

                self.portal
                    .send(PHOENIX_TOPIC, EgressMessages::AuthorizeFlowOk { reference });
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
                .update_relays(BTreeSet::from_iter(disconnected_ids), connected),
            phoenix_channel::Event::InboundMessage {
                msg: IngressMessages::Init(init),
                ..
            } => {
                self.tunnel.update_relays(BTreeSet::default(), init.relays);

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
