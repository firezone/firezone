use anyhow::{Context as _, Result};
use boringtun::x25519::PublicKey;
use connlib_model::DomainName;
#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use firezone_bin_shared::TunDeviceManager;
use firezone_logging::{telemetry_event, telemetry_span};
use firezone_tunnel::messages::gateway::{
    AllowAccess, ClientIceCandidates, ClientsIceCandidates, ConnectionReady, EgressMessages,
    IngressMessages, RejectAccess, RequestConnection,
};
use firezone_tunnel::messages::{ConnectionAccepted, GatewayResponse, RelaysPresence};
use firezone_tunnel::{
    DnsResourceNatEntry, GatewayTunnel, ResolveDnsRequest, IPV4_PEERS, IPV6_PEERS,
};
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use std::collections::BTreeSet;
use std::convert::Infallible;
use std::net::IpAddr;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use std::{io, mem};
use tokio::sync::Mutex;
use tracing::Instrument;

pub const PHOENIX_TOPIC: &str = "gateway";

/// How long we allow a DNS resolution via `libc::get_addr_info`.
const DNS_RESOLUTION_TIMEOUT: Duration = Duration::from_secs(10);

// DNS resolution happens as part of every connection setup.
// For a connection to succeed, DNS resolution must be less than `snownet`'s handshake timeout.
static_assertions::const_assert!(
    DNS_RESOLUTION_TIMEOUT.as_secs() < snownet::HANDSHAKE_TIMEOUT.as_secs()
);

#[derive(Debug)]
enum ResolveTrigger {
    RequestConnection(RequestConnection), // Deprecated
    AllowAccess(AllowAccess),             // Deprecated
    SetupNat(ResolveDnsRequest),
}

pub struct Eventloop {
    tunnel: GatewayTunnel,
    portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
    tun_device_manager: Arc<Mutex<TunDeviceManager>>,

    resolve_tasks: futures_bounded::FuturesTupleSet<Result<Vec<IpAddr>>, ResolveTrigger>,
    set_interface_tasks: futures_bounded::FuturesSet<Result<()>>,

    logged_permission_denied: bool,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: GatewayTunnel,
        mut portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
        tun_device_manager: TunDeviceManager,
    ) -> Self {
        portal.connect(PublicKeyParam(tunnel.public_key().to_bytes()));

        Self {
            tunnel,
            portal,
            tun_device_manager: Arc::new(Mutex::new(tun_device_manager)),
            resolve_tasks: futures_bounded::FuturesTupleSet::new(DNS_RESOLUTION_TIMEOUT, 1000),
            set_interface_tasks: futures_bounded::FuturesSet::new(Duration::from_secs(5), 10),
            logged_permission_denied: false,
        }
    }
}

impl Eventloop {
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<Infallible, Error>> {
        loop {
            match self.tunnel.poll_next_event(cx) {
                Poll::Ready(Ok(event)) => {
                    self.handle_tunnel_event(event);
                    continue;
                }
                Poll::Ready(Err(e))
                    if e.kind() == io::ErrorKind::NetworkUnreachable
                        || e.kind() == io::ErrorKind::HostUnreachable =>
                {
                    // Network unreachable most likely means we don't have IPv4 or IPv6 connectivity.
                    continue;
                }
                Poll::Ready(Err(e)) if e.kind() == io::ErrorKind::PermissionDenied => {
                    if !mem::replace(&mut self.logged_permission_denied, true) {
                        tracing::info!("Encountered `PermissionDenied` IO error. Check your local firewall rules to allow outbound STUN/TURN/WireGuard and general UDP traffic.")
                    }

                    continue;
                }
                Poll::Ready(Err(e)) => {
                    debug_assert_ne!(
                        e.kind(),
                        io::ErrorKind::WouldBlock,
                        "Tunnel should never emit WouldBlock errors but suspend instead"
                    );

                    let e = anyhow::Error::from(e);

                    if e.root_cause().is::<ip_packet::ImpossibleTranslation>() {
                        // Some IP packets cannot be translated and should be dropped "silently".
                        // Do so by ignoring the error here.
                        continue;
                    }

                    telemetry_event!("Tunnel error: {e:#}");
                    continue;
                }
                Poll::Pending => {}
            }

            match self.resolve_tasks.poll_unpin(cx).map(|(r, trigger)| {
                (
                    r.unwrap_or_else(|e| {
                        Err(anyhow::Error::new(e).context("DNS resolution timed out"))
                    }),
                    trigger,
                )
            }) {
                Poll::Ready((result, ResolveTrigger::RequestConnection(req))) => {
                    self.accept_connection(result, req);
                    continue;
                }
                Poll::Ready((result, ResolveTrigger::AllowAccess(req))) => {
                    self.allow_access(result, req);
                    continue;
                }
                Poll::Ready((result, ResolveTrigger::SetupNat(request))) => {
                    if let Err(e) = self.tunnel.state_mut().handle_domain_resolved(
                        request,
                        result,
                        Instant::now(),
                    ) {
                        tracing::warn!("Failed to set DNS resource NAT: {e:#}");
                    };

                    continue;
                }
                Poll::Pending => {}
            }

            match self.set_interface_tasks.poll_unpin(cx) {
                Poll::Ready(result) => {
                    result
                        .unwrap_or_else(|e| Err(anyhow::Error::new(e)))
                        .context("Failed to update TUN interface")?;
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
                msg: IngressMessages::AuthorizeFlow(msg),
                ..
            } => {
                if let Err(snownet::NoTurnServers {}) = self.tunnel.state_mut().authorize_flow(
                    msg.client.id,
                    PublicKey::from(msg.client.public_key.0),
                    msg.client.preshared_key,
                    msg.client_ice_credentials,
                    msg.gateway_ice_credentials,
                    msg.client.ipv4,
                    msg.client.ipv6,
                    msg.expires_at,
                    msg.resource,
                    Instant::now(),
                ) {
                    tracing::debug!("Failed to authorise flow: No TURN servers available");

                    // Re-connecting to the portal means we will receive another `init` and thus new TURN servers.
                    self.portal
                        .connect(PublicKeyParam(self.tunnel.public_key().to_bytes()));
                    return;
                };

                self.portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::FlowAuthorized {
                        reference: msg.reference,
                    },
                );
            }
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

                if self
                    .set_interface_tasks
                    .try_push({
                        let tun_device_manager = self.tun_device_manager.clone();

                        async move {
                            let mut tun_device_manager = tun_device_manager.lock().await;

                            tun_device_manager
                                .set_ips(init.interface.ipv4, init.interface.ipv6)
                                .await
                                .context("Failed to set TUN interface IPs")?;
                            tun_device_manager
                                .set_routes(vec![IPV4_PEERS], vec![IPV6_PEERS])
                                .await
                                .context("Failed to set TUN routes")?;

                            Ok(())
                        }
                    })
                    .is_err()
                {
                    tracing::warn!("Too many 'Update TUN device' tasks");
                };
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
            phoenix_channel::Event::Hiccup {
                backoff,
                max_elapsed_time,
                error,
            } => tracing::debug!(?backoff, ?max_elapsed_time, "{error:#}"),
        }
    }

    pub fn accept_connection(&mut self, result: Result<Vec<IpAddr>>, req: RequestConnection) {
        let addresses = match result {
            Ok(addresses) => addresses,
            Err(e) => {
                tracing::debug!(client = %req.client.id, reference = %req.reference, "DNS resolution failed as part of connection request: {e:#}");

                return; // Fail the connection so the client runs into a timeout.
            }
        };

        let answer = match self.tunnel.state_mut().accept(
            req.client.id,
            req.client
                .payload
                .ice_parameters
                .into_snownet_offer(req.client.peer.preshared_key),
            PublicKey::from(req.client.peer.public_key.0),
            Instant::now(),
        ) {
            Ok(a) => a,
            Err(snownet::NoTurnServers {}) => {
                tracing::debug!("Failed to accept new connection: No TURN servers available");

                // Re-connecting to the portal means we will receive another `init` and thus new TURN servers.
                self.portal
                    .connect(PublicKeyParam(self.tunnel.public_key().to_bytes()));

                return;
            }
        };

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
                }),
            }),
        );
    }

    pub fn allow_access(&mut self, result: Result<Vec<IpAddr>>, req: AllowAccess) {
        // "allow access" doesn't have a response so we can't tell the client that things failed.
        // It is legacy code so don't bother ...
        let addresses = match result {
            Ok(addresses) => addresses,
            Err(e) => {
                tracing::debug!(client = %req.client_id, reference = %req.reference, "DNS resolution failed as part of allow access request: {e:#}");

                vec![]
            }
        };

        if let Err(e) = self.tunnel.state_mut().allow_access(
            req.client_id,
            req.client_ipv4,
            req.client_ipv6,
            req.expires_at,
            req.resource,
            req.payload.map(|r| DnsResourceNatEntry::new(r, addresses)),
        ) {
            tracing::warn!(client = %req.client_id, "Allow access request failed: {e:#}");
        };
    }
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Failed to login to portal: {0}")]
    PhoenixChannel(#[from] phoenix_channel::Error),
    #[error("Failed to update TUN device: {0:#}")]
    UpdateTun(#[from] anyhow::Error),
}

async fn resolve(domain: Option<DomainName>) -> Result<Vec<IpAddr>> {
    let Some(domain) = domain.clone() else {
        return Ok(vec![]);
    };

    let dname = domain.to_string();

    let addresses = tokio::task::spawn_blocking(move || resolve_addresses(&dname))
        .instrument(telemetry_span!("resolve_dns_resource"))
        .await
        .context("DNS resolution task failed")?
        .context("DNS resolution failed")?;

    Ok(addresses)
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
