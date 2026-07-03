use anyhow::{Context as _, ErrorExt, Result};
use bin_shared::{TunDeviceManager, signals};
use dns_types::DomainName;
use telemetry::analytics;

use hickory_resolver::TokioResolver;
use hickory_resolver::lookup::Lookup;
use hickory_resolver::proto::rr::RecordType;
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use std::collections::{BTreeMap, BTreeSet};
use std::future::{self, Future, poll_fn};
use std::net::{IpAddr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::ops::ControlFlow;
use std::pin::pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use std::{io, mem};
use tokio::sync::mpsc;
use tunnel::messages::gateway::{
    Authorization, ClientIceCandidates, ClientsIceCandidates, EgressMessages, IngressMessages,
    InitGateway, RejectAccess,
};
use tunnel::messages::{RelaysPresence, SnownetCapabilities};
use tunnel::{
    GatewayEvent, GatewayTunnel, IPV4_TUNNEL, IPV6_TUNNEL, IpConfig, ResolveDnsRequest, TunnelError,
};

use crate::RELEASE;

pub const PHOENIX_TOPIC: &str = "gateway";

/// How long we allow a DNS resolution via hickory.
const DNS_RESOLUTION_TIMEOUT: Duration = Duration::from_secs(10);

pub struct Eventloop {
    // Tunnel is `Option` because we need to take ownership on shutdown.
    tunnel: Option<GatewayTunnel>,
    tun_device_manager: TunDeviceManager,
    resolver: TokioResolver,

    /// Flow-log spool root.
    flow_logs_dir: std::path::PathBuf,

    /// The `--flow-logs` flag: keeps flow tracking on even when the portal has
    /// uploads disabled.
    force_flow_logs: bool,

    /// Whether the portal enabled flow logging; set from `init`.
    flow_logs_enabled: bool,

    resolve_tasks: futures_bounded::FuturesTupleSet<
        Result<Vec<IpAddr>, Arc<anyhow::Error>>,
        ResolveDnsRequest,
    >,
    portal_event_rx: mpsc::Receiver<Result<IngressMessages, phoenix_channel::Error>>,
    portal_cmd_tx: mpsc::Sender<PortalCommand>,

    sigint: signals::Terminate,

    logged_permission_denied: bool,

    tunnel_errors: opentelemetry::metrics::Counter<u64>,
    dns_lookup_duration: opentelemetry::metrics::Histogram<f64>,
}

enum PortalCommand {
    Send(EgressMessages),
    Close,
}

impl Eventloop {
    pub(crate) fn new(
        tunnel: GatewayTunnel,
        portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
        tun_device_manager: TunDeviceManager,
        resolver: TokioResolver,
        flow_logs_dir: std::path::PathBuf,
        force_flow_logs: bool,
    ) -> Result<Self> {
        let (portal_event_tx, portal_event_rx) = mpsc::channel(128);
        let (portal_cmd_tx, portal_cmd_rx) = mpsc::channel(128);

        tokio::spawn(phoenix_channel_event_loop(
            portal,
            PublicKeyParam(tunnel.public_key().to_bytes()),
            portal_event_tx,
            portal_cmd_rx,
            resolver.clone(),
        ));

        Ok(Self {
            tunnel: Some(tunnel),
            tun_device_manager,
            resolver,
            flow_logs_dir,
            force_flow_logs,
            flow_logs_enabled: false,
            resolve_tasks: futures_bounded::FuturesTupleSet::new(
                || futures_bounded::Delay::tokio(DNS_RESOLUTION_TIMEOUT),
                1000,
            ),
            logged_permission_denied: false,
            tunnel_errors: otel_instruments::tunnel_errors(),
            dns_lookup_duration: otel_instruments::dns_lookup_duration(),
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
    DomainResolved((Result<Vec<IpAddr>, Arc<anyhow::Error>>, ResolveDnsRequest)),
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
            CombinedEvent::DomainResolved((result, req)) => {
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
                    .try_push(self.resolve(setup_nat.domain().clone()), setup_nat)
                    .is_err()
                {
                    tracing::warn!("Too many dns resolution requests, dropping existing one");
                };
            }
            tunnel::GatewayEvent::NoRelays => {
                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::NoRelays {}))
                    .await
                    .context("Failed to send message to portal")?;
            }
            GatewayEvent::Error(error) => self.handle_tunnel_error(error)?,
        }

        Ok(())
    }

    fn handle_tunnel_error(&mut self, mut e: TunnelError) -> Result<()> {
        for e in e.drain() {
            self.tunnel_errors
                .add(1, &telemetry::otel::error_layers(&e));

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

            if e.any_is::<tunnel::UdpSocketThreadStopped>()
                || e.any_is::<tunnel::TunChannelClosed>()
            {
                return Err(e);
            }

            if let Some(e) = e.any_downcast_ref::<tunnel::UnroutablePacket>() {
                tracing::debug!(src = %e.source(), dst = %e.destination(), proto = %e.proto(), "{e:#}");
                continue;
            }

            tracing::debug!("Tunnel error: {e:#}");
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
                // Withhold the token when flow tracking is only forced on via
                // `--flow-logs`: an unattributed flow shows up on the log output
                // but is never spooled for upload.
                let flow_logs_ingest_token = msg
                    .flow_logs_ingest_token
                    .filter(|_| self.flow_logs_enabled);

                if let Some(token) = &flow_logs_ingest_token
                    && let Err(e) =
                        flow_log_writer::write_token(&self.flow_logs_dir, token.as_str())
                {
                    tracing::warn!("Failed to persist flow-log ingest token: {e:#}");
                }

                if let Err(snownet::NoTurnServers {}) = tunnel.state_mut().authorize_flow(
                    msg.client,
                    msg.client_ice_credentials,
                    msg.gateway_ice_credentials,
                    msg.expires_at,
                    msg.resource,
                    msg.use_iceless,
                    Instant::now(),
                    flow_logs_ingest_token.map(|token| token.as_str().to_owned()),
                ) {
                    tracing::debug!("Failed to authorise flow: No TURN servers available");

                    self.portal_cmd_tx
                        .send(PortalCommand::Send(EgressMessages::NoRelays {}))
                        .await
                        .context("Failed to send message to portal")?;

                    return Ok(());
                };

                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::FlowAuthorized {
                        reference: msg.reference,
                    }))
                    .await?;
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
                flow_logs,
            }) => {
                if let Some(account_slug) = account_slug {
                    telemetry::set_account_slug(account_slug.clone());

                    analytics::identify(RELEASE.to_owned(), Some(account_slug))
                }

                self.flow_logs_enabled = flow_logs.upload_enabled();

                tunnel
                    .state_mut()
                    .set_flow_logs_enabled(self.flow_logs_enabled || self.force_flow_logs);

                if let Err(e) = flow_log_upload::configure_uploads(
                    &self.flow_logs_dir,
                    &flow_logs.api_url,
                    flow_logs.upload_interval_secs,
                    flow_logs.upload_batch_size,
                ) {
                    tracing::warn!("Failed to persist flow-log upload config: {e:#}");
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
                    if let Err(e) = tunnel.state_mut().update_access_authorization_expiry(
                        cid,
                        rid,
                        expires_at,
                        Instant::now(),
                    ) {
                        tracing::debug!(%cid, %rid, "Failed to update access authorization: {e:#}");
                    }
                }

                let tun_ip_stack = self
                    .tun_device_manager
                    .set_ips(interface.ipv4, interface.ipv6)
                    .await
                    .context("Failed to set TUN interface IPs")?;

                tracing::debug!(stack = %tun_ip_stack, "Initialized TUN device");

                let routes = match tun_ip_stack {
                    bin_shared::TunIpStack::V4Only => vec![IPV4_TUNNEL.into()],
                    bin_shared::TunIpStack::V6Only => vec![IPV6_TUNNEL.into()],
                    bin_shared::TunIpStack::Dual => vec![IPV4_TUNNEL.into(), IPV6_TUNNEL.into()],
                };

                self.tun_device_manager
                    .set_routes(routes)
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
            // OBSOLETE - safe to remove this when https://github.com/firezone/firezone/pull/13714 is deployed to production.
            IngressMessages::AccessAuthorizationExpiryUpdated(_) => {}
        }

        Ok(())
    }

    fn resolve(
        &self,
        domain: DomainName,
    ) -> impl Future<Output = Result<Vec<IpAddr>, Arc<anyhow::Error>>> + use<> {
        let resolver = self.resolver.clone();
        let dns_lookup_duration = self.dns_lookup_duration.clone();

        async move {
            // Resolve `A` and `AAAA` as two independent lookups so that each is
            // recorded with its own query-type and response-code attributes.
            let ipv4 = resolve_record(&resolver, &dns_lookup_duration, &domain, RecordType::A);
            let ipv6 = resolve_record(&resolver, &dns_lookup_duration, &domain, RecordType::AAAA);

            let (ipv4, ipv6) = futures::future::join(ipv4, ipv6).await;

            Ok(ipv4.into_iter().chain(ipv6).collect())
        }
    }
}

/// Performs a single recursive DNS lookup against the upstream resolver, recording
/// its duration with `dns.question.type` and `dns.response.code` attributes.
async fn resolve_record(
    resolver: &TokioResolver,
    dns_lookup_duration: &opentelemetry::metrics::Histogram<f64>,
    domain: &DomainName,
    record_type: RecordType,
) -> Vec<IpAddr> {
    let started_at = Instant::now();
    let result = resolver.lookup(domain.to_string(), record_type).await;

    dns_lookup_duration.record(
        started_at.elapsed().as_secs_f64(),
        &crate::otel::attr::dns_lookup(record_type, &result),
    );

    match result {
        Ok(lookup) => lookup_to_ips(&lookup).collect(),
        Err(e) => {
            tracing::debug!(%domain, %record_type, "DNS lookup failed: {e}");

            Vec::new()
        }
    }
}

async fn phoenix_channel_event_loop(
    mut portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
    public_key: PublicKeyParam,
    event_tx: mpsc::Sender<Result<IngressMessages, phoenix_channel::Error>>,
    mut cmd_rx: mpsc::Receiver<PortalCommand>,
    resolver: TokioResolver,
) {
    use futures::future::Either;
    use futures::future::select;

    let ips = resolve_portal_host_ips(&resolver, portal.host()).await;
    portal.connect(ips, Duration::ZERO, public_key.clone());

    let hiccups = otel_instruments::portal_connection_hiccups();

    loop {
        match select(poll_fn(|cx| portal.poll(cx)), pin!(cmd_rx.recv())).await {
            Either::Left((Ok(phoenix_channel::Event::Message { msg, .. }), _)) => {
                if event_tx.send(Ok(msg)).await.is_err() {
                    tracing::debug!("Event channel closed: exiting phoenix-channel event-loop");
                    break;
                }
            }
            Either::Left((Ok(phoenix_channel::Event::Closed), _)) => {
                tracing::debug!("Portal connection closed: exiting phoenix-channel event-loop");
                break;
            }
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
                    body = phoenix_channel::http_error_body(&error).map(tracing::field::display),
                    "Hiccup in portal connection: {error:#}"
                );
                hiccups.add(1, &telemetry::otel::error_layers(&error));

                let ips = resolve_portal_host_ips(&resolver, portal.host()).await;
                portal.connect(ips, backoff, public_key.clone());
            }
            Either::Left((Ok(phoenix_channel::Event::Connected), _)) => {
                if let Err(phoenix_channel::NotConnected(msg)) = portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::SetSnownetCapabilities(SnownetCapabilities::LOCAL),
                ) {
                    tracing::debug!(?msg, "Failed to send snownet capabilities: Not connected");
                }
            }
            Either::Left((Err(e), _)) => {
                let _ = event_tx.send(Err(e)).await; // We don't care about the result because we are exiting anyway.

                break;
            }
            Either::Right((Some(PortalCommand::Send(msg)), _)) => {
                match portal.send(PHOENIX_TOPIC, msg) {
                    Ok(()) => {}
                    Err(phoenix_channel::NotConnected(msg)) => {
                        tracing::debug!(?msg, "Failed to send message to portal: Not connected")
                    }
                }
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

fn lookup_to_ips(lookup: &Lookup) -> impl Iterator<Item = IpAddr> + '_ {
    lookup
        .answers()
        .iter()
        .filter_map(|record| record.data.ip_addr())
}

async fn resolve_portal_host_ips(resolver: &TokioResolver, host: String) -> Vec<IpAddr> {
    resolver
        .lookup_ip(host.clone())
        .await
        .context("Failed to lookup portal host")
        .inspect_err(|e| tracing::debug!(%host, "{e:#}"))
        .map(|ips| ips.iter().collect())
        .unwrap_or_default()
}
