//! A host-driven client session with the same portal and state handlers as native clients.

use crate::CompletionPort;
use anyhow::Result;
use backoff::ExponentialBackoffBuilder;
use client_shared::{Event, Session};
use phoenix_channel::{LoginUrl, PhoenixChannel, get_user_agent};
use secrecy::SecretString;
use serde::Deserialize;
use std::{collections::VecDeque, net::IpAddr, sync::Arc, task::Poll};

#[derive(Deserialize)]
pub struct Config {
    pub api_url: String,
    pub token: String,
    pub device_id: String,
    pub device_name: Option<String>,
    #[serde(default)]
    pub internet_resource_active: bool,
    #[serde(default)]
    pub dns_servers: Vec<IpAddr>,
}

/// Owns the current-thread executor and the shared Rust event loop.
///
/// Every method must be called serially by the host. A serial DispatchQueue may
/// migrate between OS threads between calls; the runtime is entered only for a poll.
pub struct Host {
    pub session: Session,
    events: crate::DrivenEvents,
    pub port: CompletionPort,
    pending_events: VecDeque<Event>,
    pub closed: bool,
    runtime: tokio::runtime::Runtime,
}

impl Host {
    pub fn new(config: Config) -> Result<Self> {
        Self::with_factories(
            config,
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
            None,
        )
    }

    pub fn with_factories(
        config: Config,
        tcp: Arc<dyn socket_factory::SocketFactory<socket_factory::TcpSocket>>,
        udp: Arc<dyn socket_factory::SocketFactory<socket_factory::UdpSocket>>,
        certificate: Option<x509_credential::ClientCertificate>,
    ) -> Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let (session, events, port) =
            runtime.block_on(async { config.connect_with_certificate(tcp, udp, certificate) })?;
        Ok(Self {
            session,
            events,
            port,
            pending_events: VecDeque::new(),
            closed: false,
            runtime,
        })
    }

    /// Polls packet inputs, portal updates, DNS work, and due timers without waiting for I/O.
    pub fn poll(&mut self) {
        if self.closed {
            return;
        }
        let events = &mut self.events;
        let pending = &mut self.pending_events;
        let closed = &mut self.closed;
        self.runtime.block_on(async {
            tokio::task::yield_now().await;
            std::future::poll_fn(|cx| {
                for _ in 0..128 {
                    match events.poll_next(cx) {
                        Poll::Ready(Some(event)) => pending.push_back(event),
                        Poll::Ready(None) => {
                            *closed = true;
                            break;
                        }
                        Poll::Pending => break,
                    }
                }
                Poll::Ready(())
            })
            .await;
            tokio::task::yield_now().await;
        });
    }

    pub fn next_event(&mut self) -> Option<Event> {
        self.pending_events.pop_front()
    }
}

pub fn event_json(event: Event) -> serde_json::Value {
    use serde_json::json;
    match event {
        Event::TunInterfaceUpdated(config) => {
            let (v4, v6) = config.routes.iter().map(|route| json!({"address":route.network_address().to_string(), "prefix":route.netmask()})).zip(config.routes.iter()).partition::<Vec<_>, _>(|(_, route)| route.is_ipv4());
            json!({"kind":"tun_config", "ipv4":config.ip.v4, "ipv6":config.ip.v6,
                "dns":config.dns_by_sentinel.sentinel_ips(), "search_domain":config.search_domain.map(|domain| domain.to_string()),
                "ipv4_routes":v4.into_iter().map(|(route, _)| route).collect::<Vec<_>>(),
                "ipv6_routes":v6.into_iter().map(|(route, _)| route).collect::<Vec<_>>()})
        }
        Event::ResourcesUpdated(resources) => json!({"kind":"resources", "resources":resources}),
        Event::ConnectedToPortal(connected) => {
            json!({"kind":"connected", "account_slug":connected.account_slug, "actor_name":connected.actor_name})
        }
        Event::AllGatewaysOffline { resource_id } => {
            json!({"kind":"all_gateways_offline", "resource_id":resource_id})
        }
        Event::GatewayVersionMismatch { resource_id } => {
            json!({"kind":"gateway_version_mismatch", "resource_id":resource_id})
        }
        Event::Disconnected(error) => json!({"kind":"disconnected", "error":error.user_message()}),
    }
}

impl Config {
    /// Constructs the reusable portal and state driver within the current runtime.
    pub fn connect(
        self,
        tcp: Arc<dyn socket_factory::SocketFactory<socket_factory::TcpSocket>>,
        udp: Arc<dyn socket_factory::SocketFactory<socket_factory::UdpSocket>>,
    ) -> Result<(Session, crate::DrivenEvents, CompletionPort)> {
        let result = self.connect_with_certificate(tcp, udp, None)?;
        Ok(result)
    }

    pub fn connect_with_certificate(
        self,
        tcp: Arc<dyn socket_factory::SocketFactory<socket_factory::TcpSocket>>,
        udp: Arc<dyn socket_factory::SocketFactory<socket_factory::UdpSocket>>,
        certificate: Option<x509_credential::ClientCertificate>,
    ) -> Result<(Session, crate::DrivenEvents, CompletionPort)> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        tunnel_bypass_resolver::configure(tcp.clone(), udp.clone());
        let url = LoginUrl::client(
            self.api_url.as_str(),
            self.device_id,
            self.device_name,
            phoenix_channel::DeviceInfo::default(),
            certificate,
        )?;
        let portal = PhoenixChannel::disconnected(
            url,
            Some(SecretString::from(self.token)),
            get_user_agent("completion-prototype", env!("CARGO_PKG_VERSION")),
            "client",
            (),
            || ExponentialBackoffBuilder::default().build(),
            tcp.clone(),
        );
        Ok(crate::connect(
            tcp,
            udp,
            portal,
            self.internet_resource_active,
            self.dns_servers,
            None,
            false,
        ))
    }
}
