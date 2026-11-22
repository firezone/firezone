use crate::{ConnectedAs, PHOENIX_TOPIC, SessionConfig};
use anyhow::{Context as _, ErrorExt as _, Result};
use bootstrap_dns_client::BootstrapDnsClient;
use clock::Clock;
use connlib_model::{PublicKey, ResourceId, ResourceView};
use parking_lot::Mutex;
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::ops::ControlFlow;
use std::pin::pin;
use std::sync::Arc;
use std::time::Duration;
use std::{
    collections::{BTreeMap, BTreeSet},
    io,
    net::IpAddr,
    task::{Context, Poll},
};
use std::{future, iter, mem};
use tokio::sync::{mpsc, watch};
use tun::Tun;
use tunnel::messages::client::{
    DeviceDomainBrowseFailed, DeviceDomainBrowsed, DeviceDomainResolutionFailed,
    DeviceDomainResolved, FailReason, ResourceFiltersUpdated,
};
use tunnel::messages::device::{
    AccessDenied, AccessRevoked, Authorization, BroadcastIceCandidates, DeauthorizePeer,
    EgressMessages, IceCandidates, IceCandidatesUndeliverable, IngressMessages, Init,
    PublicKeyChanged, ServedSites,
};
use tunnel::messages::{IngestToken, RelaysPresence};
use tunnel::unroutable_packet::RoutingError;
use tunnel::{DeviceEvent, DnsResourceRecord, ResolveDnsRequest, TunConfig, Tunnel, TunnelError};

/// How long we allow resolving the domain of a DNS resource we serve.
const DNS_RESOLUTION_TIMEOUT: Duration = Duration::from_secs(10);

/// In-memory cache for DNS resource records.
///
/// This is cached in a `static` to ensure it persists across sessions but gets cleared
/// once the process stops.
///
/// The ideal lifetime of this cache would be that of the current "boot session" of the computer.
/// That would ensure that network connections to IPs handed out by the stub resolver will
/// always point to the same resource.
///
/// On Linux and Windows, the process is a background-service and needs to be explicitly stopped.
/// Therefore, this will most likely outlive any other network connection unless the user messes with it.
///
/// On MacOS, iOS and Android, the OS manages the background-service for us.
/// Thus, while being disconnected, the OS may terminate the process and therefore clear this cache.
/// In most cases, the process will however stay around which makes this solution workable.
///
/// One alternative would be a file-system based cache.
/// That however means we need to define a more explicit eviction policy to stop the cache from growing.
static DNS_RESOURCE_RECORDS_CACHE: Mutex<BTreeSet<DnsResourceRecord>> = Mutex::new(BTreeSet::new());

pub struct Eventloop {
    clock: Clock,
    tunnel: Option<Tunnel>,

    resolver_bypass: tunnel_bypass_resolver::Bypass,

    /// Resolves the domains of the DNS resources we serve, outside of the tunnel.
    resolve_tasks: futures_bounded::FuturesTupleSet<
        Result<Vec<IpAddr>, Arc<anyhow::Error>>,
        ResolveDnsRequest,
    >,

    /// Flow-log spool root; the reports themselves are spooled by the
    /// entrypoint's `flow_log_writer` layer.
    flow_logs_dir: Option<std::path::PathBuf>,

    /// The `--flow-logs` flag: keeps flow tracking on even when the portal has
    /// uploads disabled.
    local_flow_logs: bool,

    cmd_rx: mpsc::UnboundedReceiver<Command>,
    resource_list_sender: watch::Sender<Vec<ResourceView>>,
    tun_config_sender: watch::Sender<Option<TunConfig>>,
    connected_as_sender: watch::Sender<Option<ConnectedAs>>,
    user_notification_sender: mpsc::Sender<UserNotification>,

    portal_event_rx: mpsc::Receiver<Result<PortalEvent, phoenix_channel::Error>>,
    portal_cmd_tx: mpsc::Sender<PortalCommand>,

    logged_permission_denied: bool,

    tunnel_errors: opentelemetry::metrics::Counter<u64>,
}

/// Commands that can be sent to the [`Eventloop`].
pub enum Command {
    Reset(String),
    Stop,
    SetDns(Vec<IpAddr>),
    SetTun(Box<dyn Tun>),
    SetInternetResourceState(bool),
    SetAdditionalHostCandidates(Vec<IpAddr>),
    SetForceRelayedConnections(bool),
}

#[derive(Debug, PartialEq, Eq, Hash)]
pub enum UserNotification {
    AllGatewaysOffline { resource_id: ResourceId },
    GatewayVersionMismatch { resource_id: ResourceId },
}

enum PortalCommand {
    Connect(PublicKeyParam),
    Send(EgressMessages),
    UpdateDnsServers(Vec<IpAddr>),
}

/// An update from the portal connection task to the main event-loop.
enum PortalEvent {
    Message(IngressMessages),
    /// The portal connection (re)established.
    Connected,
    /// The portal connection dropped and is being re-established.
    Disconnected,
}

/// Unified error type to use across connlib.
#[derive(thiserror::Error, Debug)]
#[error("{0:#}")]
pub struct DisconnectError(anyhow::Error);

impl From<anyhow::Error> for DisconnectError {
    fn from(e: anyhow::Error) -> Self {
        Self(e)
    }
}

impl DisconnectError {
    /// Returns the sentence to show the user.
    ///
    /// Only [`phoenix_channel::Error`] is worded for a user. Anything else that ends a session
    /// is an internal failure, which the user is told about without the diagnostics.
    pub fn user_message(&self) -> String {
        let Some(e) = self.0.any_downcast_ref::<phoenix_channel::Error>() else {
            return "Firezone ran into an unrecoverable error.".to_owned();
        };

        e.to_string()
    }

    /// Returns whether the error is worded for the user.
    ///
    /// Such an error is product copy rather than a diagnostic and must not be reported as
    /// telemetry.
    pub fn is_user_facing(&self) -> bool {
        self.0
            .any_downcast_ref::<phoenix_channel::Error>()
            .is_some()
    }

    /// Returns the error with its full cause chain, for the logs.
    pub fn log_message(&self) -> String {
        format!("{:#}", self.0)
    }

    /// Returns whether the stored token must be discarded and the user sent through sign-in again.
    ///
    /// This does not report whether the failure was authentication-related in general.
    /// Only failures that render the token itself unusable require a new sign-in.
    pub fn requires_sign_in(&self) -> bool {
        let Some(e) = self.0.any_downcast_ref::<phoenix_channel::Error>() else {
            return false;
        };

        e.requires_sign_in()
    }
}

impl Eventloop {
    pub(crate) fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        config: SessionConfig,
        portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
        cmd_rx: mpsc::UnboundedReceiver<Command>,
        resource_list_sender: watch::Sender<Vec<ResourceView>>,
        tun_config_sender: watch::Sender<Option<TunConfig>>,
        connected_as_sender: watch::Sender<Option<ConnectedAs>>,
        user_notification_sender: mpsc::Sender<UserNotification>,
    ) -> Result<Self> {
        let SessionConfig {
            listen_port,
            is_internet_resource_active,
            dns_servers,
            additional_host_candidates,
            flow_logs_dir,
            local_flow_logs,
        } = config;
        let (portal_event_tx, portal_event_rx) = mpsc::channel(128);
        let (portal_cmd_tx, portal_cmd_rx) = mpsc::channel(128);
        let mut clock = Clock::new();

        let mut tunnel = Tunnel::new(
            tcp_socket_factory.clone(),
            udp_socket_factory.clone(),
            listen_port,
            DNS_RESOURCE_RECORDS_CACHE.lock().clone(),
            is_internet_resource_active,
            BTreeSet::new(),
            clock.now(),
        )
        .context("Failed to create tunnel")?;
        // A client's platform does not route and masquerade the traffic of the resources it serves.
        tunnel.enable_userspace_forwarding(clock.now());
        tunnel.update_system_resolvers(dns_servers.clone());
        tunnel.set_additional_host_candidates(additional_host_candidates, clock.now());
        let resolver_bypass = tunnel_bypass_resolver::Bypass::with_servers(dns_servers.clone());

        let public_key = PublicKeyParam(tunnel.public_key().to_bytes());
        async_runtime::spawn_thread("fz-portal", move || {
            phoenix_channel_event_loop(
                portal,
                public_key,
                portal_event_tx,
                portal_cmd_rx,
                udp_socket_factory,
                tcp_socket_factory,
                dns_servers,
            )
        })
        .context("Failed to spawn portal thread")?;

        Ok(Self {
            clock,
            tunnel: Some(tunnel),
            resolver_bypass,
            resolve_tasks: futures_bounded::FuturesTupleSet::new(
                || futures_bounded::Delay::tokio(DNS_RESOLUTION_TIMEOUT),
                1000,
            ),
            flow_logs_dir,
            local_flow_logs,
            cmd_rx,
            logged_permission_denied: false,
            tunnel_errors: otel_instruments::tunnel_errors(),
            portal_event_rx,
            portal_cmd_tx,
            resource_list_sender,
            tun_config_sender,
            connected_as_sender,
            user_notification_sender,
        })
    }
}

enum CombinedEvent {
    Command(Option<Command>),
    Tunnel(Result<DeviceEvent, TunnelError>),
    Portal(Option<Result<PortalEvent, phoenix_channel::Error>>),
    Clock(clock::Event),
    DomainResolved((Result<Vec<IpAddr>, Arc<anyhow::Error>>, ResolveDnsRequest)),
}

impl Eventloop {
    pub async fn run(mut self) -> Result<(), DisconnectError> {
        loop {
            match self.tick().await {
                Ok(ControlFlow::Continue(())) => continue,
                Ok(ControlFlow::Break(())) => {
                    self.shut_down_tunnel().await?;

                    return Ok(());
                }
                Err(e) => {
                    if !e.requires_sign_in() {
                        tracing::error!("Fatal tunnel error: {e:#}");
                    }

                    // Ignore error from shutdown to not obscure the original error.
                    let _ = self.shut_down_tunnel().await;

                    return Err(e);
                }
            }
        }
    }

    async fn tick(&mut self) -> Result<ControlFlow<(), ()>, DisconnectError> {
        match future::poll_fn(|cx| self.next_event(cx)).await {
            CombinedEvent::Command(None) => Ok(ControlFlow::Break(())),
            CombinedEvent::Command(Some(cmd)) => {
                let cf = self.handle_eventloop_command(cmd).await?;

                Ok(cf)
            }
            CombinedEvent::Tunnel(event) => {
                self.handle_tunnel_event(event).await?;

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::Clock(clock::Event::Alarm(now)) => {
                if let Some(tunnel) = self.tunnel.as_mut() {
                    tunnel.handle_timeout(now);
                }

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::Clock(clock::Event::Late(by)) => {
                let cf = self
                    .handle_eventloop_command(Command::Reset(format!(
                        "event loop ran {by:.0?} late"
                    )))
                    .await?;

                Ok(cf)
            }
            CombinedEvent::Portal(Some(Ok(PortalEvent::Message(msg)))) => {
                self.handle_portal_message(msg).await?;

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::Portal(Some(Ok(PortalEvent::Connected))) => {
                if let Some(tunnel) = self.tunnel.as_mut() {
                    tunnel.state_mut().set_portal_connected(true);
                }

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::Portal(Some(Ok(PortalEvent::Disconnected))) => {
                if let Some(tunnel) = self.tunnel.as_mut() {
                    tunnel.state_mut().set_portal_connected(false);
                }

                Ok(ControlFlow::Continue(()))
            }
            CombinedEvent::Portal(Some(Err(e))) => Err(DisconnectError(
                anyhow::Error::new(e).context("Connection to portal failed"),
            )),
            CombinedEvent::Portal(None) => Err(DisconnectError(anyhow::Error::msg(
                "portal task exited unexpectedly",
            ))),
            CombinedEvent::DomainResolved((result, request)) => {
                let now = self.clock.now();
                let Some(tunnel) = self.tunnel.as_mut() else {
                    tracing::debug!("Ignoring DNS resolution result during shutdown");

                    return Ok(ControlFlow::Continue(()));
                };

                if let Err(e) = tunnel
                    .state_mut()
                    .handle_domain_resolved(request, result, now)
                {
                    tracing::warn!("Failed to set DNS resource NAT: {e:#}");
                }

                Ok(ControlFlow::Continue(()))
            }
        }
    }

    async fn handle_eventloop_command(&mut self, command: Command) -> Result<ControlFlow<(), ()>> {
        match command {
            Command::Stop => return Ok(ControlFlow::Break(())),
            Command::SetDns(dns) => {
                let Some(tunnel) = self.tunnel.as_mut() else {
                    return Ok(ControlFlow::Continue(()));
                };

                let dns = tunnel.update_system_resolvers(dns);
                self.resolver_bypass.update_servers(dns.clone());

                self.portal_cmd_tx
                    .send(PortalCommand::UpdateDnsServers(dns))
                    .await
                    .context("Failed to send message to portal")?;
            }
            Command::SetInternetResourceState(active) => {
                let now = self.clock.now();
                let Some(tunnel) = self.tunnel.as_mut() else {
                    return Ok(ControlFlow::Continue(()));
                };

                tunnel.state_mut().set_internet_resource_state(active, now)
            }
            Command::SetAdditionalHostCandidates(ips) => {
                let now = self.clock.now();
                let Some(tunnel) = self.tunnel.as_mut() else {
                    return Ok(ControlFlow::Continue(()));
                };

                tunnel.set_additional_host_candidates(ips, now);
            }
            Command::SetForceRelayedConnections(enabled) => {
                let Some(tunnel) = self.tunnel.as_ref() else {
                    return Ok(ControlFlow::Continue(()));
                };

                tracing::info!(enabled, "Setting force relayed connections");

                tunnel.set_force_relayed_connections(enabled);
            }
            Command::SetTun(tun) => {
                let Some(tunnel) = self.tunnel.as_mut() else {
                    return Ok(ControlFlow::Continue(()));
                };

                tunnel.set_tun(tun);
            }
            Command::Reset(reason) => {
                let now = self.clock.now();
                let Some(tunnel) = self.tunnel.as_mut() else {
                    return Ok(ControlFlow::Continue(()));
                };

                tunnel.state_mut().set_portal_connected(false);
                tunnel.reset(&reason, now);
                tunnel_bypass_resolver::reset_sockets();
                telemetry::reset_ingest();
                self.portal_cmd_tx
                    .send(PortalCommand::Connect(PublicKeyParam(
                        tunnel.public_key().to_bytes(),
                    )))
                    .await
                    .context("Failed to connect phoenix-channel")?;
            }
        }

        Ok(ControlFlow::Continue(()))
    }

    async fn handle_tunnel_event(&mut self, event: Result<DeviceEvent, TunnelError>) -> Result<()> {
        match event {
            Ok(DeviceEvent::AddedIceCandidates {
                conn_id,
                candidates,
            }) => {
                tracing::debug!(%conn_id, ?candidates, "Sending new ICE candidates");

                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::BroadcastIceCandidates(
                        BroadcastIceCandidates {
                            device_ids: vec![conn_id],
                            candidates,
                        },
                    )))
                    .await
                    .context("Failed to send message to portal")?;
            }
            Ok(DeviceEvent::RemovedIceCandidates {
                conn_id,
                candidates,
            }) => {
                tracing::debug!(%conn_id, ?candidates, "Sending invalidated ICE candidates");

                self.portal_cmd_tx
                    .send(PortalCommand::Send(
                        EgressMessages::BroadcastInvalidatedIceCandidates(BroadcastIceCandidates {
                            device_ids: vec![conn_id],
                            candidates,
                        }),
                    ))
                    .await
                    .context("Failed to send message to portal")?;
            }
            Ok(DeviceEvent::RequestAccess {
                resource_ids,
                ip,
                preferred_gateways,
            }) => {
                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::RequestAccess {
                        resource_ids,
                        device_ip: ip,
                        connected_device_ids: preferred_gateways,
                    }))
                    .await
                    .context("Failed to send message to portal")?;
            }
            Ok(DeviceEvent::DeviceDomainQueried { domain }) => {
                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::ResolveDeviceDomain {
                        domain: domain.to_string(),
                    }))
                    .await
                    .context("Failed to send message to portal")?;
            }
            Ok(DeviceEvent::DeviceDomainBrowsed { domain }) => {
                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::BrowseDeviceDomain {
                        domain: domain.to_string(),
                    }))
                    .await
                    .context("Failed to send message to portal")?;
            }
            Ok(DeviceEvent::ResourcesChanged { resources }) => {
                self.resource_list_sender
                    .send(resources)
                    .context("Failed to emit event")?;
            }
            Ok(DeviceEvent::TunInterfaceUpdated(config)) => {
                self.tun_config_sender
                    .send(Some(config))
                    .context("Failed to emit event")?;
            }
            Ok(DeviceEvent::DnsRecordsChanged { records }) => {
                *DNS_RESOURCE_RECORDS_CACHE.lock() = records;
            }
            Ok(DeviceEvent::NoRelays { excluded_relay_ids }) => {
                self.portal_cmd_tx
                    .send(PortalCommand::Send(EgressMessages::NoRelays {
                        excluded_relay_ids,
                    }))
                    .await
                    .context("Failed to send message to portal")?;
            }
            Ok(DeviceEvent::ResolveDns(request)) => {
                let domain = request.domain().to_string();
                let resolution = async move {
                    tunnel_bypass_resolver::resolve(&domain)
                        .await
                        .map_err(Arc::new)
                };

                if self.resolve_tasks.try_push(resolution, request).is_err() {
                    tracing::warn!("Too many DNS resolution requests, dropping existing one");
                }
            }
            Err(error) => self.handle_tunnel_error(error)?,
        }

        Ok(())
    }

    fn handle_tunnel_error(&mut self, mut e: TunnelError) -> Result<()> {
        for e in e.drain() {
            self.tunnel_errors
                .add(1, &otel_attributes::error_layers(&e));

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
                || e.any_is::<socket_factory::RoutingLoopPreventionFailed>()
            {
                return Err(e);
            }

            if e.any_downcast_ref::<tunnel::UnroutablePacket>()
                .is_some_and(|e| e.reason() == RoutingError::RoutingLoop)
                && telemetry::feature_flags::fail_on_routing_loop()
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
        let now = self.clock.now();
        let Some(tunnel) = self.tunnel.as_mut() else {
            return Ok(());
        };

        match msg {
            IngressMessages::Init(Init {
                interface,
                resources,
                relays,
                served_sites,
                served_resources,
                authorizations,
                flow_logs,
                account_slug,
                actor_name,
            }) => {
                self.connected_as_sender
                    .send(Some(ConnectedAs {
                        account_slug,
                        actor_name,
                    }))
                    .context("Failed to emit event")?;

                tracing::info!(
                    upload_enabled = flow_logs.upload_enabled(),
                    spool_dir = ?self.flow_logs_dir,
                    config = ?flow_logs,
                    "Flow-log config received from portal init"
                );

                tunnel.state_mut().set_flow_logs_enabled(
                    (flow_logs.upload_enabled() && self.flow_logs_dir.is_some())
                        || self.local_flow_logs,
                );

                if let Some(spool_root) = &self.flow_logs_dir {
                    match flow_log_upload::configure_uploads(
                        spool_root,
                        &flow_logs.api_url,
                        flow_logs.upload_interval_secs,
                        flow_logs.upload_batch_size,
                    )
                    .context("Failed to persist flow-log upload config")
                    {
                        Ok(()) => {}
                        Err(e)
                            if e.any_downcast_ref::<std::io::Error>()
                                .is_some_and(|io| io.kind() == std::io::ErrorKind::StorageFull) =>
                        {
                            tracing::debug!("{e:#}");
                        }
                        Err(e) => {
                            tracing::warn!("{e:#}");
                        }
                    }
                }

                tracing::debug!(sites = ?served_sites, "Serving sites");

                let state = tunnel.state_mut();

                state.update_interface_config(interface);
                state.set_resources(resources, now);
                state.set_served_resources(served_resources, now);
                state.update_relays(BTreeSet::default(), tunnel::turn(&relays), now);

                state.retain_authorizations(authorizations.iter().fold(
                    BTreeMap::<_, BTreeSet<_>>::new(),
                    |mut grouped, authorization| {
                        grouped
                            .entry(authorization.device_id)
                            .or_default()
                            .insert(authorization.resource_id);
                        grouped
                    },
                ));
                for Authorization {
                    device_id,
                    resource_id,
                    expires_at,
                } in authorizations
                {
                    let Some(expires_at) = expires_at else {
                        continue;
                    };

                    state.update_access_authorization_expiry(
                        device_id,
                        resource_id,
                        expires_at,
                        now,
                    );
                }
            }
            IngressMessages::ConfigChanged(config) => {
                tunnel.state_mut().update_interface_config(config.interface)
            }
            IngressMessages::RelaysPresence(RelaysPresence {
                disconnected_ids,
                connected,
            }) => tunnel.state_mut().update_relays(
                BTreeSet::from_iter(disconnected_ids),
                tunnel::turn(&connected),
                now,
            ),
            IngressMessages::ResourceCreatedOrUpdated(resource) => {
                tunnel.state_mut().add_resource(resource, now);
            }
            IngressMessages::ResourceDeleted(resource) => {
                tunnel.state_mut().remove_resource(resource, now);
            }
            IngressMessages::ResourceFiltersUpdated(ResourceFiltersUpdated { id, filters }) => {
                tunnel
                    .state_mut()
                    .handle_resource_filters_updated(id, filters);
            }
            IngressMessages::ServedSitesChanged(ServedSites {
                served_sites,
                served_resources,
            }) => {
                tracing::debug!(sites = ?served_sites, "Serving sites");

                tunnel
                    .state_mut()
                    .set_served_resources(served_resources, now);
            }
            IngressMessages::ServedResourceCreatedOrUpdated(resource) => {
                tunnel.state_mut().update_served_resource(resource);
            }
            IngressMessages::ServedResourceDeleted(resource) => {
                tunnel.state_mut().remove_served_resource(resource, now);
            }
            IngressMessages::AuthorizePeer(authorize) => {
                persist_ingest_token(
                    self.flow_logs_dir.as_deref(),
                    &authorize.flow_logs_ingest_token,
                );

                match tunnel.state_mut().handle_authorize_peer(authorize, now) {
                    Ok(reference) => {
                        self.portal_cmd_tx
                            .send(PortalCommand::Send(EgressMessages::PeerAuthorized {
                                reference,
                            }))
                            .await
                            .context("Failed to send message to portal")?;
                    }
                    Err(e) => {
                        tracing::warn!("Failed to authorize peer: {e:#}");
                    }
                }
            }
            IngressMessages::AccessGranted(granted) => {
                persist_ingest_token(
                    self.flow_logs_dir.as_deref(),
                    &granted.flow_logs_ingest_token,
                );

                if let Err(e) = tunnel.state_mut().handle_access_granted(granted, now) {
                    tracing::warn!("Failed to handle granted access: {e:#}");
                }
            }
            IngressMessages::AccessDenied(AccessDenied::Resource {
                resource_id,
                reason,
                ..
            }) => {
                tracing::debug!(%resource_id, "Access to resource denied: {reason:?}");

                match reason {
                    FailReason::Offline => {
                        tunnel.state_mut().set_resource_offline(resource_id, now);

                        let _ = self
                            .user_notification_sender
                            .send(UserNotification::AllGatewaysOffline { resource_id })
                            .await;
                    }
                    FailReason::VersionMismatch => {
                        let _ = self
                            .user_notification_sender
                            .send(UserNotification::GatewayVersionMismatch { resource_id })
                            .await;
                    }
                    FailReason::NotFound
                    | FailReason::Forbidden
                    | FailReason::Disabled
                    | FailReason::AmbiguousAddress
                    | FailReason::MissingAddress
                    | FailReason::InvalidAddress
                    | FailReason::NotADevice
                    | FailReason::Unknown => {}
                }
            }
            IngressMessages::AccessDenied(AccessDenied::Device { ipv4, ipv6, reason }) => {
                tunnel
                    .state_mut()
                    .handle_client_device_access_denied(ipv4, ipv6, reason);
            }
            IngressMessages::DeauthorizePeer(DeauthorizePeer {
                device_id,
                resource_id,
            }) => {
                tunnel
                    .state_mut()
                    .deauthorize_peer(device_id, resource_id, now);
            }
            IngressMessages::AccessRevoked(AccessRevoked {
                device_id,
                resource_id,
            }) => {
                tunnel
                    .state_mut()
                    .handle_access_revoked(device_id, resource_id);
            }
            IngressMessages::PublicKeyChanged(PublicKeyChanged {
                device_id,
                public_key,
            }) => {
                tunnel.state_mut().handle_public_key_changed(
                    device_id,
                    PublicKey::from(public_key.0),
                    now,
                );
            }
            IngressMessages::IceCandidates(IceCandidates {
                device_id,
                candidates,
            }) => {
                for candidate in candidates {
                    tunnel
                        .state_mut()
                        .add_ice_candidate(device_id, candidate, now)
                }
            }
            IngressMessages::InvalidateIceCandidates(IceCandidates {
                device_id,
                candidates,
            }) => {
                for candidate in candidates {
                    tunnel
                        .state_mut()
                        .remove_ice_candidate(device_id, candidate, now)
                }
            }
            IngressMessages::IceCandidatesUndeliverable(IceCandidatesUndeliverable {
                device_id,
                reason,
            }) => {
                tracing::debug!(%device_id, ?reason, "ICE candidates could not be delivered to peer");

                match reason {
                    FailReason::Offline => {
                        tunnel.state_mut().set_device_offline(device_id, now);
                    }
                    FailReason::NotFound
                    | FailReason::VersionMismatch
                    | FailReason::Forbidden
                    | FailReason::Disabled
                    | FailReason::AmbiguousAddress
                    | FailReason::MissingAddress
                    | FailReason::InvalidAddress
                    | FailReason::NotADevice
                    | FailReason::Unknown => {}
                }
            }
            IngressMessages::DeviceDomainResolved(DeviceDomainResolved { domain, ipv4, ipv6 }) => {
                let Some(domain) = parse_portal_domain(&domain) else {
                    return Ok(());
                };
                tunnel
                    .state_mut()
                    .handle_device_domain_resolved(domain, Ok((ipv4, ipv6)), now);
            }
            IngressMessages::DeviceDomainResolutionFailed(DeviceDomainResolutionFailed {
                domain,
                reason,
            }) => {
                let Some(domain) = parse_portal_domain(&domain) else {
                    return Ok(());
                };
                tunnel
                    .state_mut()
                    .handle_device_domain_resolved(domain, Err(reason), now);
            }
            IngressMessages::DeviceDomainBrowsed(DeviceDomainBrowsed {
                domain,
                names,
                ttl,
                total,
            }) => {
                let Some(domain) = parse_portal_domain(&domain) else {
                    return Ok(());
                };
                let names = names
                    .iter()
                    .filter_map(|name| parse_portal_domain(name))
                    .collect();
                tunnel.state_mut().handle_device_domain_browsed(
                    domain,
                    Ok((names, ttl, total)),
                    now,
                );
            }
            IngressMessages::DeviceDomainBrowseFailed(DeviceDomainBrowseFailed {
                domain,
                reason,
            }) => {
                let Some(domain) = parse_portal_domain(&domain) else {
                    return Ok(());
                };
                tunnel
                    .state_mut()
                    .handle_device_domain_browsed(domain, Err(reason), now);
            }
        }

        Ok(())
    }

    fn next_event(&mut self, cx: &mut Context) -> Poll<CombinedEvent> {
        if let Poll::Ready(event) = self.clock.poll_event(cx) {
            return Poll::Ready(CombinedEvent::Clock(event));
        }

        if let Poll::Ready(cmd) = self.cmd_rx.poll_recv(cx) {
            return Poll::Ready(CombinedEvent::Command(cmd));
        }

        if let Poll::Ready(event) = self.portal_event_rx.poll_recv(cx) {
            return Poll::Ready(CombinedEvent::Portal(event));
        }

        if let Poll::Ready((result, request)) = self.resolve_tasks.poll_unpin(cx) {
            let result = result.unwrap_or_else(|e| {
                Err(Arc::new(
                    anyhow::Error::new(e).context("DNS resolution timed out"),
                ))
            });

            return Poll::Ready(CombinedEvent::DomainResolved((result, request)));
        }

        let now = self.clock.now();
        if let Some(tunnel) = self.tunnel.as_mut() {
            if let Poll::Ready(event) = tunnel.poll_next_event(cx, now) {
                return Poll::Ready(CombinedEvent::Tunnel(event));
            }

            // Nothing to do until the tunnel's next deadline: ask once, then suspend. Being
            // sampled well past that deadline means we were not running, not that we had nothing
            // to do.
            self.clock.set_alarm(cx, tunnel.next_timeout(now));
        }

        Poll::Pending
    }

    async fn shut_down_tunnel(&mut self) -> Result<()> {
        let now = self.clock.now();
        let Some(tunnel) = self.tunnel.take() else {
            tracing::debug!("Tunnel has already been shut down");
            return Ok(());
        };

        tunnel
            .shut_down(now)
            .await
            .context("Failed to shut down tunnel")?;

        Ok(())
    }
}

/// Tokens deliberately travel here rather than through the flow-log tracing
/// events, so they can never leak into log output.
fn persist_ingest_token(spool_root: Option<&std::path::Path>, token: &IngestToken) {
    let Some(spool_root) = spool_root else {
        return;
    };

    if !token.claims().uploads_enabled {
        return;
    }

    match flow_log_writer::write_token(spool_root, token.as_str())
        .context("Failed to persist flow-log ingest token")
    {
        Ok(()) => {}
        Err(e)
            if e.any_downcast_ref::<std::io::Error>()
                .is_some_and(|io| io.kind() == std::io::ErrorKind::StorageFull) =>
        {
            tracing::debug!("{e:#}");
        }
        Err(e) => {
            tracing::warn!("{e:#}");
        }
    }
}

async fn phoenix_channel_event_loop(
    mut portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
    mut public_key: PublicKeyParam,
    event_tx: mpsc::Sender<Result<PortalEvent, phoenix_channel::Error>>,
    mut cmd_rx: mpsc::Receiver<PortalCommand>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    dns_servers: Vec<IpAddr>,
) {
    use futures::future::Either;
    use futures::future::select;
    use std::future::poll_fn;

    let mut bootstrap_dns_client = BootstrapDnsClient::new(
        udp_socket_factory.clone(),
        tcp_socket_factory.clone(),
        dns_servers,
    );

    let ips = resolve_portal_host_ips(&bootstrap_dns_client, portal.host()).await;
    portal.connect(ips, Duration::ZERO, public_key.clone());

    let hiccups = otel_instruments::portal_connection_hiccups();

    loop {
        // We process commands from the channel first (i.e. it is polled first) to update the DNS servers as quickly as possible.
        // This allows `Hiccup` events to use the updated `BootstrapDnsClient` to resolve the domain.
        match select(pin!(cmd_rx.recv()), poll_fn(|cx| portal.poll(cx))).await {
            Either::Left((Some(PortalCommand::Send(msg)), _)) => {
                match portal.send(PHOENIX_TOPIC, msg) {
                    Ok(()) => {}
                    Err(phoenix_channel::NotConnected(msg)) => {
                        tracing::debug!(?msg, "Failed to send message to portal: Not connected")
                    }
                }
            }
            Either::Left((Some(PortalCommand::Connect(new_public_key)), _)) => {
                public_key = new_public_key; // Important! Update the current public key so we can reuse on connection hiccups!

                let ips = resolve_portal_host_ips(&bootstrap_dns_client, portal.host()).await;
                portal.connect(ips, Duration::ZERO, public_key.clone());
            }
            Either::Left((Some(PortalCommand::UpdateDnsServers(servers)), _)) => {
                bootstrap_dns_client = BootstrapDnsClient::new(
                    udp_socket_factory.clone(),
                    tcp_socket_factory.clone(),
                    servers,
                );
            }
            Either::Left((None, _)) => {
                tracing::debug!("Command channel closed: exiting phoenix-channel event-loop");

                break;
            }
            Either::Right((Ok(phoenix_channel::Event::Message { msg, .. }), _)) => {
                if event_tx.send(Ok(PortalEvent::Message(msg))).await.is_err() {
                    tracing::debug!("Event channel closed: exiting phoenix-channel event-loop");

                    break;
                }
            }
            Either::Right((Ok(phoenix_channel::Event::Closed), _)) => {
                unimplemented!("Client never actively closes the portal connection")
            }
            Either::Right((
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
                hiccups.add(1, &otel_attributes::error_layers(&error));

                let _ = event_tx.send(Ok(PortalEvent::Disconnected)).await;

                let ips = resolve_portal_host_ips(&bootstrap_dns_client, portal.host()).await;
                portal.connect(ips, backoff, public_key.clone());
            }
            Either::Right((Ok(phoenix_channel::Event::Connected), _)) => {
                let _ = event_tx.send(Ok(PortalEvent::Connected)).await;
            }
            Either::Right((Err(e), _)) => {
                let _ = event_tx.send(Err(e)).await; // We don't care about the result because we are exiting anyway.

                break;
            }
        }
    }
}

/// Re-resolves the IPs of the portal hostname.
///
/// We combine the result of two sources here:
///
/// - We make DNS queries to our configured system resolvers.
/// - We read `/etc/hosts`.
///
/// If any of these fail, we simply default to an empty list of IPs.
/// This is fine as this routine will be triggered again if we ever run out of IPs to use.
async fn resolve_portal_host_ips(
    bootstrap_dns_client: &BootstrapDnsClient,
    host: String,
) -> Vec<IpAddr> {
    let dns_ips = bootstrap_dns_client
        .resolve(host.clone())
        .await
        .context("Failed to lookup portal host via DNS")
        .inspect_err(|e| tracing::debug!(%host, "{e:#}"))
        .unwrap_or_default();

    let etc_hosts_ips = etc_hosts_dns_client::resolve(&host)
        .context("Failed to lookup portal host from `/etc/hosts`")
        .inspect_err(|e| tracing::debug!(%host, "{e:#}"))
        .unwrap_or_default();

    iter::empty().chain(dns_ips).chain(etc_hosts_ips).collect()
}

fn parse_portal_domain(domain: &str) -> Option<dns_types::DomainName> {
    domain
        .parse()
        .inspect_err(|e| {
            tracing::warn!(%domain, "Portal sent malformed device pool domain: {}", logging::err_with_src(e));
        })
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signing_failure_names_the_certificate_but_not_the_keystore() {
        let error = portal_failure(phoenix_channel::Error::ClientCertificateSigningFailed(
            "the keystore failed to sign: The requested operation is not supported. (0x80090029)"
                .into(),
        ));

        assert_eq!(
            error.user_message(),
            "This device could not sign in with its certificate"
        );
        assert_eq!(
            error.log_message(),
            "Connection to portal failed: This device could not sign in with its certificate: the keystore failed to sign: The requested operation is not supported. (0x80090029)"
        );
    }

    #[test]
    fn lost_connection_names_the_portal_but_not_the_last_attempt() {
        let error = portal_failure(phoenix_channel::Error::MaxRetriesReached {
            final_error: "websocket connection failed".into(),
        });

        assert_eq!(
            error.user_message(),
            "The connection to the Firezone Portal was lost and could not be restored"
        );
        assert_eq!(
            error.log_message(),
            "Connection to portal failed: The connection to the Firezone Portal was lost and could not be restored: websocket connection failed"
        );
    }

    #[test]
    fn failures_without_a_message_for_the_user_are_reported_as_unrecoverable() {
        let error = DisconnectError::from(
            anyhow::Error::msg("failed to write to TUN device").context("connlib crashed"),
        );

        assert_eq!(
            error.user_message(),
            "Firezone ran into an unrecoverable error."
        );
        assert_eq!(
            error.log_message(),
            "connlib crashed: failed to write to TUN device"
        );
    }

    fn portal_failure(error: phoenix_channel::Error) -> DisconnectError {
        DisconnectError(anyhow::Error::new(error).context("Connection to portal failed"))
    }
}
