use anyhow::{Context as _, ErrorExt as _, Result};
use bin_shared::{TunDeviceManager, signals};
use boringtun::x25519::PublicKey;
#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};
use dns_types::DomainName;
use telemetry::{Telemetry, analytics};

use futures::{FutureExt as _, TryFutureExt};
use hickory_resolver::TokioResolver;
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use std::collections::{BTreeMap, BTreeSet};
use std::future::{self, Future, poll_fn};
use std::net::{IpAddr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::ops::ControlFlow;
use std::pin::pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use std::{io, iter, mem};
use tokio::sync::mpsc;
use tunnel::messages::gateway::{
    AccessAuthorizationExpiryUpdated, AllowAccess, Authorization, ClientIceCandidates,
    ClientsIceCandidates, ConnectionReady, EgressMessages, IngressMessages, InitGateway,
    RejectAccess, RequestConnection,
};
use tunnel::messages::{ConnectionAccepted, GatewayResponse, RelaysPresence};
use tunnel::{
    DnsResourceNatEntry, GatewayEvent, GatewayTunnel, IPV4_TUNNEL, IPV6_TUNNEL, IpConfig,
    ResolveDnsRequest, TunnelError,
};

use crate::RELEASE;

pub const PHOENIX_TOPIC: &str = "gateway";

/// How long we allow a DNS resolution via hickory.
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
    // Tunnel is `Option` because we need to take ownership on shutdown.
    tunnel: Option<GatewayTunnel>,
    tun_device_manager: TunDeviceManager,
    resolver: TokioResolver,

    resolve_tasks:
        futures_bounded::FuturesTupleSet<Result<Vec<IpAddr>, Arc<anyhow::Error>>, ResolveTrigger>,
    portal_event_rx: mpsc::Receiver<Result<IngressMessages, phoenix_channel::Error>>,
    portal_cmd_tx: mpsc::Sender<PortalCommand>,

    dns_cache: moka::future::Cache<DomainName, Vec<IpAddr>>,

    sigint: signals::Terminate,

    logged_permission_denied: bool,
}

enum PortalCommand {
    Send(EgressMessages),
    Connect(PublicKeyParam),
    Close,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: GatewayTunnel,
        mut portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
        tun_device_manager: TunDeviceManager,
        resolver: TokioResolver,
    ) -> Result<Self> {
        portal.connect(PublicKeyParam(tunnel.public_key().to_bytes()));

        let (portal_event_tx, portal_event_rx) = mpsc::channel(128);
        let (portal_cmd_tx, portal_cmd_rx) = mpsc::channel(128);

        tokio::spawn(phoenix_channel_event_loop(
            portal,
            portal_event_tx,
            portal_cmd_rx,
            resolver.clone(),
        ));

        Ok(Self {
            tunnel: Some(tunnel),
            tun_device_manager,
            resolver,
            resolve_tasks: futures_bounded::FuturesTupleSet::new(
                || futures_bounded::Delay::tokio(DNS_RESOLUTION_TIMEOUT),
                1000,
            ),
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
            sigint: signals::Terminate::new()?,
        })
    }
}

enum CombinedEvent {
    SigIntTerm,
    Tunnel(GatewayEvent),
    Portal(Option<Result<IngressMessages, phoenix_channel::Error>>),
    DomainResolved((Result<Vec<IpAddr>, Arc<anyhow::Error>>, ResolveTrigger)),
}

impl Eventloop {
    pub async fn run(mut self) -> Result<()> {
        loop {
            match self.tick().await {
                Ok(ControlFlow::Continue(())) => continue,
                Ok(ControlFlow::Break(())) => {
                    self.shut_down_tunnel().await?;

                    return Ok(());
                }
                Err(e) => {
                    // Ignore shutdown error here to not obscure the original error.
                    let _ = self.shut_down_tunnel().await;

                    return Err(e);
                }
            }
        }
    }

    pub async fn tick(&mut self) -> Result<ControlFlow<(), ()>> {
        match future::poll_fn(|cx| self.next_event(cx)).await {
            CombinedEvent::Tunnel(event) => {
                self.handle_tunnel_event(event).await?;

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::Portal(Some(Ok(msg))) => {
                self.handle_portal_message(msg).await?;

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::Portal(None) => Err(anyhow::Error::msg(
                "phoenix channel task stopped unexpectedly",
            )),
            CombinedEvent::Portal(Some(Err(e))) => Err(e).context("Failed to login to portal"),
            CombinedEvent::DomainResolved((result, ResolveTrigger::RequestConnection(req))) => {
                self.accept_connection(result, req).await?;

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::DomainResolved((result, ResolveTrigger::AllowAccess(req))) => {
                self.allow_access(result, req);

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::DomainResolved((result, ResolveTrigger::SetupNat(req))) => {
                let Some(tunnel) = self.tunnel.as_mut() else {
                    tracing::debug!("Ignoring DNS resolution result during shutdown");

                    return Ok(ControlFlow::Continue(()));
                };

                if let Err(e) =
                    tunnel
                        .state_mut()
                        .handle_domain_resolved(req, result, Instant::now())
                {
                    tracing::warn!("Failed to set DNS resource NAT: {e:#}");
                };

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::SigIntTerm => {
                tracing::info!("Received SIGINT/SIGTERM");

                self.portal_cmd_tx.send(PortalCommand::Close).await?;

                Ok(ControlFlow::Break(()))
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

        if let Some(Poll::Ready(event)) = self.tunnel.as_mut().map(|t| t.poll_next_event(cx)) {
            return Poll::Ready(CombinedEvent::Tunnel(event));
        }

        if let Poll::Ready(()) = self.sigint.poll_recv(cx) {
            return Poll::Ready(CombinedEvent::SigIntTerm);
        }

        Poll::Pending
    }

    async fn shut_down_tunnel(&mut self) -> Result<()> {
        let Some(tunnel) = self.tunnel.take() else {
            tracing::debug!("Tunnel has already been shut down");

            return Ok(());
        };

        tunnel
            .shut_down()
            .await
            .context("Failed to shutdown tunnel")?;

        Ok(())
    }

    async fn handle_tunnel_event(&mut self, event: tunnel::GatewayEvent) -> Result<()> {
        match event {
            tunnel::GatewayEvent::AddedIceCandidates {
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
            tunnel::GatewayEvent::RemovedIceCandidates {
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
            tunnel::GatewayEvent::ResolveDns(setup_nat) => {
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
            GatewayEvent::Error(error) => self.handle_tunnel_error(error)?,
        }

        Ok(())
    }

    fn handle_tunnel_error(&mut self, mut e: TunnelError) -> Result<()> {
        for e in e.drain() {
            if e.any_downcast_ref::<io::Error>()
                .is_some_and(is_unreachable)
            {
                tracing::debug!("{e:#}"); // Log these on DEBUG so they don't go completely unnoticed.
                continue;
            }

            // Invalid Input can be all sorts of things but we mostly see it with unreachable addresses.
            if e.any_downcast_ref::<io::Error>()
                .is_some_and(|e| e.kind() == io::ErrorKind::InvalidInput)
            {
                tracing::debug!("{e:#}");
                continue;
            }

            if e.any_downcast_ref::<io::Error>()
                .is_some_and(|e| e.kind() == io::ErrorKind::PermissionDenied)
            {
                if !mem::replace(&mut self.logged_permission_denied, true) {
                    tracing::info!(
                        "Encountered `PermissionDenied` IO error. Check your local firewall rules to allow outbound STUN/TURN/WireGuard and general UDP traffic."
                    )
                }

                continue;
            }

            if e.any_is::<ip_packet::ImpossibleTranslation>() {
                // Some IP packets cannot be translated and should be dropped "silently".
                // Do so by ignoring the error here.
                continue;
            }

            if let Some(e) = e.any_downcast_ref::<tunnel::UnroutablePacket>() {
                tracing::debug!(src = %e.source(), dst = %e.destination(), proto = %e.proto(), "{e:#}");
                continue;
            }

            if e.any_is::<tunnel::UdpSocketThreadStopped>() {
                return Err(e);
            }

            tracing::warn!("Tunnel error: {e:#}");
        }

        Ok(())
    }

    async fn handle_portal_message(&mut self, msg: IngressMessages) -> Result<()> {
        let Some(tunnel) = self.tunnel.as_mut() else {
            tracing::debug!(?msg, "Ignoring portal message during shutdown");

            return Ok(());
        };

        match msg {
            IngressMessages::AuthorizeFlow(msg) => {
                if let Err(snownet::NoTurnServers {}) = tunnel.state_mut().authorize_flow(
                    msg.client,
                    msg.subject,
                    msg.client_ice_credentials,
                    msg.gateway_ice_credentials,
                    msg.expires_at,
                    msg.resource,
                    Instant::now(),
                ) {
                    tracing::debug!("Failed to authorise flow: No TURN servers available");

                    // Re-connecting to the portal means we will receive another `init` and thus new TURN servers.
                    self.portal_cmd_tx
                        .send(PortalCommand::Connect(PublicKeyParam(
                            tunnel.public_key().to_bytes(),
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
                    tunnel
                        .state_mut()
                        .add_ice_candidate(client_id, candidate, Instant::now());
                }
            }
            IngressMessages::InvalidateIceCandidates(ClientIceCandidates {
                client_id,
                candidates,
            }) => {
                for candidate in candidates {
                    tunnel
                        .state_mut()
                        .remove_ice_candidate(client_id, candidate, Instant::now());
                }
            }
            IngressMessages::RejectAccess(RejectAccess {
                client_id,
                resource_id,
            }) => {
                tunnel
                    .state_mut()
                    .remove_access(&client_id, &resource_id, Instant::now());
            }
            IngressMessages::RelaysPresence(RelaysPresence {
                disconnected_ids,
                connected,
            }) => tunnel.state_mut().update_relays(
                BTreeSet::from_iter(disconnected_ids),
                tunnel::turn(&connected),
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

                tunnel.state_mut().update_relays(
                    BTreeSet::default(),
                    tunnel::turn(&relays),
                    Instant::now(),
                );
                tunnel.state_mut().update_tun_device(IpConfig {
                    v4: interface.ipv4,
                    v6: interface.ipv6,
                });
                tunnel
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
                    if let Err(e) = tunnel
                        .state_mut()
                        .update_access_authorization_expiry(cid, rid, expires_at)
                    {
                        tracing::debug!(%cid, %rid, "Failed to update access authorization: {e:#}");
                    }
                }

                let tun_ip_stack = self
                    .tun_device_manager
                    .set_ips(interface.ipv4, interface.ipv6)
                    .await
                    .context("Failed to set TUN interface IPs")?;

                tracing::debug!(stack = %tun_ip_stack, "Initialized TUN device");

                self.tun_device_manager
                    .set_routes(vec![IPV4_TUNNEL], vec![IPV6_TUNNEL])
                    .await
                    .context("Failed to set TUN routes")?;

                let ipv4_socket = SocketAddr::V4(SocketAddrV4::new(interface.ipv4, 53535));
                let ipv6_socket = SocketAddr::V6(SocketAddrV6::new(interface.ipv6, 53535, 0, 0));

                let addresses = match tun_ip_stack {
                    bin_shared::TunIpStack::V4Only => vec![ipv4_socket],
                    bin_shared::TunIpStack::V6Only => vec![ipv6_socket],
                    bin_shared::TunIpStack::Dual => vec![ipv4_socket, ipv6_socket],
                };

                let mut attempts = std::iter::repeat_n(addresses, 3);

                loop {
                    let Some(attempt) = attempts.next() else {
                        anyhow::bail!("Failed to bind DNS servers on TUN interface");
                    };

                    match tunnel.rebind_dns(attempt) {
                        Ok(()) => break,
                        Err(mut e) => {
                            for e in e.drain() {
                                tracing::debug!("Failed to bind DNS server: {e:#}")
                            }
                        }
                    }

                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
            IngressMessages::ResourceUpdated(resource_description) => {
                tunnel.state_mut().update_resource(resource_description);
            }
            IngressMessages::AccessAuthorizationExpiryUpdated(
                AccessAuthorizationExpiryUpdated {
                    client_id: cid,
                    resource_id: rid,
                    expires_at,
                },
            ) => {
                if let Err(e) = tunnel
                    .state_mut()
                    .update_access_authorization_expiry(cid, rid, expires_at)
                {
                    tracing::debug!(%cid, %rid, "Failed to update expiry of access authorization: {e:#}")
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
        let Some(tunnel) = self.tunnel.as_mut() else {
            tracing::debug!(?req, "Ignoring incoming connection during shutdown");

            return Ok(());
        };

        let addresses = match result {
            Ok(addresses) => addresses,
            Err(e) => {
                tracing::debug!(cid = %req.client.id, reference = %req.reference, "DNS resolution failed as part of connection request: {e:#}");

                return Ok(()); // Fail the connection so the client runs into a timeout.
            }
        };

        let answer = match tunnel.state_mut().accept(
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
                        tunnel.public_key().to_bytes(),
                    )))
                    .await?;

                return Ok(());
            }
        };

        if let Err(e) = tunnel.state_mut().allow_access(
            req.client.id,
            IpConfig {
                v4: req.client.peer.ipv4,
                v6: req.client.peer.ipv6,
            },
            Default::default(), // Additional client properties are not supported for 1.3.x Clients and will just be empty.
            req.expires_at,
            req.resource,
            req.client
                .payload
                .domain
                .map(|r| DnsResourceNatEntry::new(r, addresses)),
        ) {
            let cid = req.client.id;

            tunnel.state_mut().cleanup_connection(&cid, Instant::now());
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
        let Some(tunnel) = self.tunnel.as_mut() else {
            return;
        };

        // "allow access" doesn't have a response so we can't tell the client that things failed.
        // It is legacy code so don't bother ...
        let addresses = match result {
            Ok(addresses) => addresses,
            Err(e) => {
                tracing::debug!(cid = %req.client_id, reference = %req.reference, "DNS resolution failed as part of allow access request: {e:#}");

                vec![]
            }
        };

        if let Err(e) = tunnel.state_mut().allow_access(
            req.client_id,
            IpConfig {
                v4: req.client_ipv4,
                v6: req.client_ipv6,
            },
            Default::default(), // Additional client properties are not supported for 1.3.x Clients and will just be empty.
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
        if telemetry::feature_flags::gateway_userspace_dns_a_aaaa_records() {
            let resolver = self.resolver.clone();

            async move {
                let ipv4_lookup = resolver
                    .ipv4_lookup(domain.to_string())
                    .map_ok(|ipv4| ipv4.into_iter().map(|r| IpAddr::V4(r.0)));
                let ipv6_lookup = resolver
                    .ipv6_lookup(domain.to_string())
                    .map_ok(|ipv6| ipv6.into_iter().map(|r| IpAddr::V6(r.0)));

                let ips = match futures::future::join(ipv4_lookup, ipv6_lookup).await {
                    (Ok(ipv4), Ok(ipv6)) => iter::empty().chain(ipv4).chain(ipv6).collect(),
                    (Ok(ipv4), Err(e)) => {
                        tracing::debug!(%domain, "AAAA lookup failed: {e}");

                        ipv4.collect()
                    }
                    (Err(e), Ok(ipv6)) => {
                        tracing::debug!(%domain, "A lookup failed: {e}");

                        ipv6.collect()
                    }
                    (Err(e1), Err(e2)) => {
                        tracing::debug!(%domain, "A and AAAA lookup failed: [{e1}; {e2}]");

                        vec![]
                    }
                };

                Ok(ips)
            }
            .boxed()
        } else {
            let do_resolve = resolve(domain.clone());
            let cache = self.dns_cache.clone();

            async move { cache.try_get_with(domain, do_resolve).await }.boxed()
        }
    }
}

async fn phoenix_channel_event_loop(
    mut portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
    event_tx: mpsc::Sender<Result<IngressMessages, phoenix_channel::Error>>,
    mut cmd_rx: mpsc::Receiver<PortalCommand>,
    resolver: TokioResolver,
) {
    use futures::future::Either;
    use futures::future::select;

    update_portal_host_ips(&mut portal, &resolver).await;

    loop {
        match select(poll_fn(|cx| portal.poll(cx)), pin!(cmd_rx.recv())).await {
            Either::Left((Ok(phoenix_channel::Event::InboundMessage { msg, .. }), _)) => {
                if event_tx.send(Ok(msg)).await.is_err() {
                    tracing::debug!("Event channel closed: exiting phoenix-channel event-loop");
                    break;
                }
            }
            Either::Left((
                Ok(phoenix_channel::Event::ErrorResponse {
                    topic,
                    res: phoenix_channel::ErrorReply::UnmatchedTopic,
                    ..
                }),
                _,
            )) => {
                portal.join(topic, ());
            }
            Either::Left((Ok(phoenix_channel::Event::ErrorResponse { topic, req_id, res }), _)) => {
                tracing::warn!(%topic, %req_id, "Request failed: {res:?}");
            }
            Either::Left((Ok(phoenix_channel::Event::Closed), _)) => {
                tracing::debug!("Portal connection clsed: exiting phoenix-channel event-loop");
                break;
            }
            Either::Left((
                Ok(
                    phoenix_channel::Event::SuccessResponse { .. }
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
            )) => {
                tracing::info!(
                    ?backoff,
                    ?max_elapsed_time,
                    "Hiccup in portal connection: {error:#}"
                );
            }
            Either::Left((Ok(phoenix_channel::Event::NoAddresses), _)) => {
                update_portal_host_ips(&mut portal, &resolver).await
            }
            Either::Left((Err(e), _)) => {
                let _ = event_tx.send(Err(e)).await; // We don't care about the result because we are exiting anyway.

                break;
            }
            Either::Right((Some(PortalCommand::Send(msg)), _)) => {
                portal.send(PHOENIX_TOPIC, msg);
            }
            Either::Right((Some(PortalCommand::Connect(param)), _)) => {
                portal.connect(param);
            }
            Either::Right((Some(PortalCommand::Close), _)) => {
                let _ = portal.close();
            }
            Either::Right((None, _)) => {
                tracing::debug!("Command channel closed: exiting phoenix-channel event-loop");
                break;
            }
        }
    }
}

async fn update_portal_host_ips(
    portal: &mut PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
    resolver: &TokioResolver,
) {
    let ips = match resolver
        .lookup_ip(portal.host())
        .await
        .context("Failed to lookup portal host")
    {
        Ok(ips) => ips.into_iter().collect(),
        Err(e) => {
            tracing::debug!(host = %portal.host(), "{e:#}");
            return;
        }
    };

    portal.update_ips(ips);
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
