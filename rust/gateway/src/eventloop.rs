use anyhow::{Context as _, Result};
use boringtun::x25519::PublicKey;
#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use dns_types::DomainName;
use firezone_bin_shared::TunDeviceManager;
use firezone_telemetry::{Telemetry, analytics};

use firezone_tunnel::messages::gateway::{
    AccessAuthorizationExpiryUpdated, AllowAccess, Authorization, ClientIceCandidates,
    ClientsIceCandidates, ConnectionReady, EgressMessages, IngressMessages, InitGateway,
    RejectAccess, RequestConnection,
};
use firezone_tunnel::messages::{ConnectionAccepted, GatewayResponse, RelaysPresence};
use firezone_tunnel::{
    DnsResourceNatEntry, GatewayEvent, GatewayTunnel, IPV4_TUNNEL, IPV6_TUNNEL, IpConfig,
    ResolveDnsRequest,
};
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use std::collections::{BTreeMap, BTreeSet};
use std::convert::Infallible;
use std::future::{self, Future, poll_fn};
use std::net::{IpAddr, SocketAddrV4, SocketAddrV6};
use std::pin::pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use std::{io, mem};
use tokio::sync::mpsc;

use crate::RELEASE;

pub const PHOENIX_TOPIC: &str = "gateway";

/// How long we allow a DNS resolution via `libc::get_addr_info`.
const DNS_RESOLUTION_TIMEOUT: Duration = Duration::from_secs(10);

/// Cache DNS responses for 30 seconds.
const DNS_TTL: Duration = Duration::from_secs(30);

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
    tun_device_manager: TunDeviceManager,

    resolve_tasks:
        futures_bounded::FuturesTupleSet<Result<Vec<IpAddr>, Arc<anyhow::Error>>, ResolveTrigger>,
    portal_event_rx: mpsc::Receiver<Result<IngressMessages, phoenix_channel::Error>>,
    portal_cmd_tx: mpsc::Sender<PortalCommand>,

    dns_cache: moka::future::Cache<DomainName, Vec<IpAddr>>,

    logged_permission_denied: bool,
}

enum PortalCommand {
    Send(EgressMessages),
    Connect(PublicKeyParam),
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: GatewayTunnel,
        mut portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
        tun_device_manager: TunDeviceManager,
    ) -> Self {
        portal.connect(PublicKeyParam(tunnel.public_key().to_bytes()));

        let (portal_event_tx, portal_event_rx) = mpsc::channel(128);
        let (portal_cmd_tx, portal_cmd_rx) = mpsc::channel(128);

        tokio::spawn(phoenix_channel_event_loop(
            portal,
            portal_event_tx,
            portal_cmd_rx,
        ));

        Self {
            tunnel,
            tun_device_manager,
            resolve_tasks: futures_bounded::FuturesTupleSet::new(DNS_RESOLUTION_TIMEOUT, 1000),
            logged_permission_denied: false,
            dns_cache: moka::future::Cache::builder()
                .name("DNS queries")
                .time_to_live(DNS_TTL)
                .eviction_listener(|domain, ips, cause| {
                    tracing::debug!(%domain, ?ips, ?cause, "DNS cache entry evicted");
                })
                .build(),
            portal_event_rx,
            portal_cmd_tx,
        }
    }
}

enum CombinedEvent {
    Tunnel(Result<GatewayEvent>),
    Portal(Option<Result<IngressMessages, phoenix_channel::Error>>),
    DomainResolved((Result<Vec<IpAddr>, Arc<anyhow::Error>>, ResolveTrigger)),
}

impl Eventloop {
    pub async fn run(mut self) -> Result<Infallible> {
        loop {
            match future::poll_fn(|cx| self.next_event(cx)).await {
                CombinedEvent::Tunnel(Ok(event)) => {
                    self.handle_tunnel_event(event).await?;
                }
                CombinedEvent::Tunnel(Err(e)) => {
                    self.handle_tunnel_error(e)?;
                }
                CombinedEvent::Portal(Some(Ok(msg))) => {
                    self.handle_portal_message(msg).await?;
                }
                CombinedEvent::Portal(None) => {
                    return Err(anyhow::Error::msg(
                        "phoenix channel task stoppe unexpectedly",
                    ));
                }
                CombinedEvent::Portal(Some(Err(e))) => {
                    return Err(e).context("Failed to login to portal");
                }
                CombinedEvent::DomainResolved((result, ResolveTrigger::RequestConnection(req))) => {
                    self.accept_connection(result, req).await?;
                }
                CombinedEvent::DomainResolved((result, ResolveTrigger::AllowAccess(req))) => {
                    self.allow_access(result, req);
                }
                CombinedEvent::DomainResolved((result, ResolveTrigger::SetupNat(req))) => {
                    if let Err(e) =
                        self.tunnel
                            .state_mut()
                            .handle_domain_resolved(req, result, Instant::now())
                    {
                        tracing::warn!("Failed to set DNS resource NAT: {e:#}");
                    };
                }
            }
        }
    }

    fn next_event(&mut self, cx: &mut Context<'_>) -> Poll<CombinedEvent> {
        if let Poll::Ready(event) = self.portal_event_rx.poll_recv(cx) {
            return Poll::Ready(CombinedEvent::Portal(event));
        }

        if let Poll::Ready((result, trigger)) = self.resolve_tasks.poll_unpin(cx) {
            let result = result.unwrap_or_else(|e| {
                Err(Arc::new(
                    anyhow::Error::new(e).context("DNS resolution timed out"),
                ))
            });

            return Poll::Ready(CombinedEvent::DomainResolved((result, trigger)));
        }

        if let Poll::Ready(event) = self.tunnel.poll_next_event(cx) {
            return Poll::Ready(CombinedEvent::Tunnel(event));
        }

        Poll::Pending
    }

    async fn handle_tunnel_event(&mut self, event: firezone_tunnel::GatewayEvent) -> Result<()> {
        match event {
            firezone_tunnel::GatewayEvent::AddedIceCandidates {
                conn_id: client,
                candidates,
            } => {
                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::BroadcastIceCandidates(
                        ClientsIceCandidates {
                            client_ids: vec![client],
                            candidates,
                        },
                    )))
                    .await?;
            }
            firezone_tunnel::GatewayEvent::RemovedIceCandidates {
                conn_id: client,
                candidates,
            } => {
                self.portal_cmd_tx
                    .send(PortalCommand::Send(
                        EgressMessages::BroadcastInvalidatedIceCandidates(ClientsIceCandidates {
                            client_ids: vec![client],
                            candidates,
                        }),
                    ))
                    .await?;
            }
            firezone_tunnel::GatewayEvent::ResolveDns(setup_nat) => {
                if self
                    .resolve_tasks
                    .try_push(
                        self.resolve(setup_nat.domain().clone()),
                        ResolveTrigger::SetupNat(setup_nat),
                    )
                    .is_err()
                {
                    tracing::warn!("Too many dns resolution requests, dropping existing one");
                };
            }
        }

        Ok(())
    }

    fn handle_tunnel_error(&mut self, e: anyhow::Error) -> Result<()> {
        if e.root_cause()
            .downcast_ref::<io::Error>()
            .is_some_and(is_unreachable)
        {
            tracing::debug!("{e:#}"); // Log these on DEBUG so they don't go completely unnoticed.
            return Ok(());
        }

        // Invalid Input can be all sorts of things but we mostly see it with unreachable addresses.
        if e.root_cause()
            .downcast_ref::<io::Error>()
            .is_some_and(|e| e.kind() == io::ErrorKind::InvalidInput)
        {
            tracing::debug!("{e:#}");
            return Ok(());
        }

        // Unknown connection just means packets are bouncing on the TUN device because the Client disconnected.
        if e.root_cause().is::<snownet::UnknownConnection>() {
            tracing::debug!("{e:#}");
            return Ok(());
        }

        if e.root_cause()
            .downcast_ref::<io::Error>()
            .is_some_and(|e| e.kind() == io::ErrorKind::PermissionDenied)
        {
            if !mem::replace(&mut self.logged_permission_denied, true) {
                tracing::info!(
                    "Encountered `PermissionDenied` IO error. Check your local firewall rules to allow outbound STUN/TURN/WireGuard and general UDP traffic."
                )
            }

            return Ok(());
        }

        if e.root_cause().is::<ip_packet::ImpossibleTranslation>() {
            // Some IP packets cannot be translated and should be dropped "silently".
            // Do so by ignoring the error here.
            return Ok(());
        }

        if e.root_cause()
            .is::<firezone_tunnel::UdpSocketThreadStopped>()
        {
            return Err(e);
        }

        tracing::warn!("Tunnel error: {e:#}");

        Ok(())
    }

    async fn handle_portal_message(&mut self, msg: IngressMessages) -> Result<()> {
        match msg {
            IngressMessages::AuthorizeFlow(msg) => {
                if let Err(snownet::NoTurnServers {}) = self.tunnel.state_mut().authorize_flow(
                    msg.client.id,
                    PublicKey::from(msg.client.public_key.0),
                    msg.client.preshared_key,
                    msg.client_ice_credentials,
                    msg.gateway_ice_credentials,
                    IpConfig {
                        v4: msg.client.ipv4,
                        v6: msg.client.ipv6,
                    },
                    msg.expires_at,
                    msg.resource,
                    Instant::now(),
                ) {
                    tracing::debug!("Failed to authorise flow: No TURN servers available");

                    // Re-connecting to the portal means we will receive another `init` and thus new TURN servers.
                    self.portal_cmd_tx
                        .send(PortalCommand::Connect(PublicKeyParam(
                            self.tunnel.public_key().to_bytes(),
                        )))
                        .await?;

                    return Ok(());
                };

                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::FlowAuthorized {
                        reference: msg.reference,
                    }))
                    .await?;
            }
            IngressMessages::RequestConnection(req) => {
                let Some(domain) = req.client.payload.domain.as_ref().map(|r| r.name.clone())
                else {
                    self.accept_connection(Ok(vec![]), req).await?;
                    return Ok(());
                };

                if self
                    .resolve_tasks
                    .try_push(self.resolve(domain), ResolveTrigger::RequestConnection(req))
                    .is_err()
                {
                    tracing::warn!("Too many connections requests, dropping existing one");
                };
            }
            IngressMessages::AllowAccess(req) => {
                let Some(domain) = req.payload.as_ref().map(|r| r.name.clone()) else {
                    self.allow_access(Ok(vec![]), req);
                    return Ok(());
                };

                if self
                    .resolve_tasks
                    .try_push(self.resolve(domain), ResolveTrigger::AllowAccess(req))
                    .is_err()
                {
                    tracing::warn!("Too many allow access requests, dropping existing one");
                };
            }
            IngressMessages::IceCandidates(ClientIceCandidates {
                client_id,
                candidates,
            }) => {
                for candidate in candidates {
                    self.tunnel
                        .state_mut()
                        .add_ice_candidate(client_id, candidate, Instant::now());
                }
            }
            IngressMessages::InvalidateIceCandidates(ClientIceCandidates {
                client_id,
                candidates,
            }) => {
                for candidate in candidates {
                    self.tunnel.state_mut().remove_ice_candidate(
                        client_id,
                        candidate,
                        Instant::now(),
                    );
                }
            }
            IngressMessages::RejectAccess(RejectAccess {
                client_id,
                resource_id,
            }) => {
                self.tunnel
                    .state_mut()
                    .remove_access(&client_id, &resource_id);
            }
            IngressMessages::RelaysPresence(RelaysPresence {
                disconnected_ids,
                connected,
            }) => self.tunnel.state_mut().update_relays(
                BTreeSet::from_iter(disconnected_ids),
                firezone_tunnel::turn(&connected),
                Instant::now(),
            ),
            IngressMessages::Init(InitGateway {
                interface,
                config: _,
                account_slug,
                relays,
                authorizations,
            }) => {
                if let Some(account_slug) = account_slug {
                    Telemetry::set_account_slug(account_slug.clone());

                    analytics::identify(RELEASE.to_owned(), Some(account_slug))
                }

                self.tunnel.state_mut().update_relays(
                    BTreeSet::default(),
                    firezone_tunnel::turn(&relays),
                    Instant::now(),
                );
                self.tunnel.state_mut().update_tun_device(IpConfig {
                    v4: interface.ipv4,
                    v6: interface.ipv6,
                });
                self.tunnel
                    .state_mut()
                    .retain_authorizations(authorizations.iter().fold(
                        BTreeMap::new(),
                        |mut authorizations, next| {
                            authorizations
                                .entry(next.client_id)
                                .or_default()
                                .insert(next.resource_id);

                            authorizations
                        },
                    ));
                for Authorization {
                    client_id: cid,
                    resource_id: rid,
                    expires_at,
                } in authorizations
                {
                    if let Err(e) = self
                        .tunnel
                        .state_mut()
                        .update_access_authorization_expiry(cid, rid, expires_at)
                    {
                        tracing::debug!(%cid, %rid, "Failed to update access authorization: {e:#}");
                    }
                }

                self.tun_device_manager
                    .set_ips(interface.ipv4, interface.ipv6)
                    .await
                    .context("Failed to set TUN interface IPs")?;
                self.tun_device_manager
                    .set_routes(vec![IPV4_TUNNEL], vec![IPV6_TUNNEL])
                    .await
                    .context("Failed to set TUN routes")?;

                let ipv4_socket = SocketAddrV4::new(interface.ipv4, 53535);
                let ipv6_socket = SocketAddrV6::new(interface.ipv6, 53535, 0, 0);

                let ipv4_result = self
                    .tunnel
                    .rebind_dns_ipv4(ipv4_socket)
                    .with_context(|| format!("Failed to bind DNS server at {ipv4_socket}"))
                    .inspect_err(|e| tracing::debug!("{e:#}"));

                let ipv6_result = self
                    .tunnel
                    .rebind_dns_ipv6(ipv6_socket)
                    .with_context(|| format!("Failed to bind DNS server at {ipv6_socket}"))
                    .inspect_err(|e| tracing::debug!("{e:#}"));

                ipv4_result.or(ipv6_result)?;
            }
            IngressMessages::ResourceUpdated(resource_description) => {
                self.tunnel
                    .state_mut()
                    .update_resource(resource_description);
            }
            IngressMessages::AccessAuthorizationExpiryUpdated(
                AccessAuthorizationExpiryUpdated {
                    client_id: cid,
                    resource_id: rid,
                    expires_at,
                },
            ) => {
                if let Err(e) = self
                    .tunnel
                    .state_mut()
                    .update_access_authorization_expiry(cid, rid, expires_at)
                {
                    tracing::warn!(%cid, %rid, "Failed to update expiry of access authorization: {e:#}")
                };
            }
        }

        Ok(())
    }

    pub async fn accept_connection(
        &mut self,
        result: Result<Vec<IpAddr>, Arc<anyhow::Error>>,
        req: RequestConnection,
    ) -> Result<()> {
        let addresses = match result {
            Ok(addresses) => addresses,
            Err(e) => {
                tracing::debug!(cid = %req.client.id, reference = %req.reference, "DNS resolution failed as part of connection request: {e:#}");

                return Ok(()); // Fail the connection so the client runs into a timeout.
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
                self.portal_cmd_tx
                    .send(PortalCommand::Connect(PublicKeyParam(
                        self.tunnel.public_key().to_bytes(),
                    )))
                    .await?;

                return Ok(());
            }
        };

        if let Err(e) = self.tunnel.state_mut().allow_access(
            req.client.id,
            IpConfig {
                v4: req.client.peer.ipv4,
                v6: req.client.peer.ipv6,
            },
            req.expires_at,
            req.resource,
            req.client
                .payload
                .domain
                .map(|r| DnsResourceNatEntry::new(r, addresses)),
        ) {
            let cid = req.client.id;

            self.tunnel.state_mut().cleanup_connection(&cid);
            tracing::debug!(%cid, "Connection request failed: {e:#}");

            return Ok(());
        }

        self.portal_cmd_tx
            .send(PortalCommand::Send(EgressMessages::ConnectionReady(
                ConnectionReady {
                    reference: req.reference,
                    gateway_payload: GatewayResponse::ConnectionAccepted(ConnectionAccepted {
                        ice_parameters: answer,
                    }),
                },
            )))
            .await?;

        Ok(())
    }

    pub fn allow_access(
        &mut self,
        result: Result<Vec<IpAddr>, Arc<anyhow::Error>>,
        req: AllowAccess,
    ) {
        // "allow access" doesn't have a response so we can't tell the client that things failed.
        // It is legacy code so don't bother ...
        let addresses = match result {
            Ok(addresses) => addresses,
            Err(e) => {
                tracing::debug!(cid = %req.client_id, reference = %req.reference, "DNS resolution failed as part of allow access request: {e:#}");

                vec![]
            }
        };

        if let Err(e) = self.tunnel.state_mut().allow_access(
            req.client_id,
            IpConfig {
                v4: req.client_ipv4,
                v6: req.client_ipv6,
            },
            req.expires_at,
            req.resource,
            req.payload.map(|r| DnsResourceNatEntry::new(r, addresses)),
        ) {
            tracing::warn!(cid = %req.client_id, "Allow access request failed: {e:#}");
        };
    }

    fn resolve(
        &self,
        domain: DomainName,
    ) -> impl Future<Output = Result<Vec<IpAddr>, Arc<anyhow::Error>>> + use<> {
        let do_resolve = resolve(domain.clone());
        let cache = self.dns_cache.clone();

        async move { cache.try_get_with(domain, do_resolve).await }
    }
}

async fn phoenix_channel_event_loop(
    mut portal: PhoenixChannel<(), IngressMessages, (), PublicKeyParam>,
    event_tx: mpsc::Sender<Result<IngressMessages, phoenix_channel::Error>>,
    mut cmd_rx: mpsc::Receiver<PortalCommand>,
) {
    use futures::future::Either;
    use futures::future::select;

    loop {
        match select(poll_fn(|cx| portal.poll(cx)), pin!(cmd_rx.recv())).await {
            Either::Left((Ok(phoenix_channel::Event::InboundMessage { msg, .. }), _)) => {
                if event_tx.send(Ok(msg)).await.is_err() {
                    tracing::debug!("Event channel closed: exiting phoenix-channel event-loop");
                    break;
                }
            }
            Either::Left((Ok(phoenix_channel::Event::ErrorResponse { topic, req_id, res }), _)) => {
                tracing::warn!(%topic, %req_id, "Request failed: {res:?}");
            }
            Either::Left((Ok(phoenix_channel::Event::Closed), _)) => {
                unimplemented!("Gateway never actively closes the portal connection")
            }
            Either::Left((
                Ok(
                    phoenix_channel::Event::SuccessResponse { res: (), .. }
                    | phoenix_channel::Event::HeartbeatSent
                    | phoenix_channel::Event::JoinedRoom { .. },
                ),
                _,
            )) => {}
            Either::Left((
                Ok(phoenix_channel::Event::Hiccup {
                    backoff,
                    max_elapsed_time,
                    error,
                }),
                _,
            )) => tracing::info!(
                ?backoff,
                ?max_elapsed_time,
                "Hiccup in portal connection: {error:#}"
            ),
            Either::Left((Err(e), _)) => {
                if event_tx.send(Err(e)).await.is_err() {
                    tracing::debug!("Event channel closed: exiting phoenix-channel event-loop");
                    break;
                }
            }
            Either::Right((Some(PortalCommand::Send(msg)), _)) => {
                portal.send(PHOENIX_TOPIC, msg);
            }
            Either::Right((Some(PortalCommand::Connect(param)), _)) => {
                portal.connect(param);
            }
            Either::Right((None, _)) => {
                tracing::debug!("Command channel closed: exiting phoenix-channel event-loop");
                break;
            }
        }
    }
}

async fn resolve(domain: DomainName) -> Result<Vec<IpAddr>> {
    tracing::debug!(%domain, "Resolving DNS");

    let dname = domain.to_string();

    let addresses = tokio::task::spawn_blocking(move || resolve_addresses(&dname))
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

fn is_unreachable(e: &io::Error) -> bool {
    #[cfg(unix)]
    if e.raw_os_error().is_some_and(|e| e == libc::EHOSTDOWN) {
        return true;
    }

    e.kind() == io::ErrorKind::NetworkUnreachable
        || e.kind() == io::ErrorKind::HostUnreachable
        || e.kind() == io::ErrorKind::AddrNotAvailable
}
