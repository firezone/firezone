mod platform;

use std::{
    fmt,
    os::fd::RawFd,
    path::{Path, PathBuf},
    sync::{Arc, OnceLock},
    time::Duration,
};

use anyhow::{Context as _, Result, anyhow};
use backoff::ExponentialBackoffBuilder;
use ip_network::IpNetwork;
use itertools::Itertools as _;
use logging::sentry_layer;
use phoenix_channel::{LoginUrl, PhoenixChannel, get_user_agent};
use platform::RELEASE;
use secrecy::SecretString;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use telemetry::{Telemetry, analytics};
use tokio::sync::Mutex;
use tracing_subscriber::{Layer, layer::SubscriberExt as _};

uniffi::setup_scaffolding!();

#[derive(uniffi::Object)]
pub struct Session {
    inner: client_shared::Session,
    events: Mutex<client_shared::EventStream>,
    telemetry: Mutex<Telemetry>,
    runtime: Option<tokio::runtime::Runtime>,
}

#[derive(uniffi::Object, thiserror::Error, Debug)]
#[error("{0:#}")]
pub struct ConnlibError(anyhow::Error);

#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum CallbackError {
    #[error("{0}")]
    Failed(String),
}

#[derive(uniffi::Object, Debug)]
pub struct DisconnectError(client_shared::DisconnectError);

/// Represents a CIDR network (address + prefix length).
/// Used for IPv4 and IPv6 route configuration.
#[derive(uniffi::Record)]
pub struct Cidr {
    pub address: String,
    pub prefix: u8,
}

/// Device information for telemetry and identification.
#[derive(uniffi::Record)]
pub struct DeviceInfo {
    pub firebase_installation_id: Option<String>,
    pub device_uuid: Option<String>,
    pub device_serial: Option<String>,
    pub identifier_for_vendor: Option<String>,
}

/// Resource status enum
#[derive(uniffi::Enum)]
pub enum ResourceStatus {
    Unknown,
    Online,
    Offline,
}

/// Site information for a resource
#[derive(uniffi::Record)]
pub struct Site {
    pub id: String,
    pub name: String,
}

/// DNS resource view
#[derive(uniffi::Record)]
pub struct DnsResource {
    pub id: String,
    pub address: String,
    pub name: String,
    pub address_description: Option<String>,
    pub sites: Vec<Site>,
    pub status: ResourceStatus,
}

/// CIDR resource view
#[derive(uniffi::Record)]
pub struct CidrResource {
    pub id: String,
    pub address: String,
    pub name: String,
    pub address_description: Option<String>,
    pub sites: Vec<Site>,
    pub status: ResourceStatus,
}

/// Internet resource view
#[derive(uniffi::Record)]
pub struct InternetResource {
    pub id: String,
    pub name: String,
    pub sites: Vec<Site>,
    pub status: ResourceStatus,
}

/// Resource view enum
#[derive(uniffi::Enum)]
pub enum Resource {
    Dns { resource: DnsResource },
    Cidr { resource: CidrResource },
    Internet { resource: InternetResource },
}

#[derive(uniffi::Enum)]
pub enum Event {
    TunInterfaceUpdated {
        ipv4: String,
        ipv6: String,
        dns: Vec<String>,
        search_domain: Option<String>,
        ipv4_routes: Vec<Cidr>,
        ipv6_routes: Vec<Cidr>,
    },
    ResourcesUpdated {
        resources: Vec<Resource>,
    },
    Disconnected {
        error: Arc<DisconnectError>,
    },
}

#[uniffi::export]
impl DisconnectError {
    pub fn message(&self) -> String {
        self.0.to_string()
    }

    pub fn is_authentication_error(&self) -> bool {
        self.0.is_authentication_error()
    }
}

#[uniffi::export(with_foreign)]
pub trait ProtectSocket: Send + Sync + fmt::Debug {
    fn protect_socket(&self, fd: RawFd) -> Result<(), CallbackError>;
}

#[uniffi::export]
#[cfg(target_os = "android")]
impl Session {
    #[uniffi::constructor]
    #[expect(
        clippy::too_many_arguments,
        reason = "This is the API we want to expose over FFI."
    )]
    pub fn new_android(
        api_url: String,
        token: String,
        device_id: String,
        account_slug: String,
        device_name: String,
        log_dir: String,
        log_filter: String,
        device_info: DeviceInfo,
        is_internet_resource_active: bool,
        protect_socket: Arc<dyn ProtectSocket>,
    ) -> Result<Self, ConnlibError> {
        let udp_socket_factory = Arc::new(protected_udp_socket_factory(protect_socket.clone()));
        let tcp_socket_factory = Arc::new(protected_tcp_socket_factory(protect_socket));

        connect(
            api_url,
            token,
            device_id,
            account_slug,
            Some(device_name),
            log_dir,
            log_filter,
            device_info,
            is_internet_resource_active,
            tcp_socket_factory,
            udp_socket_factory,
        )
    }
}

#[uniffi::export]
#[cfg(any(target_os = "ios", target_os = "macos"))]
impl Session {
    #[uniffi::constructor]
    #[expect(
        clippy::too_many_arguments,
        reason = "This is the API we want to expose over FFI."
    )]
    pub fn new_apple(
        api_url: String,
        token: String,
        device_id: String,
        account_slug: String,
        device_name: Option<String>,
        log_dir: String,
        log_filter: String,
        device_info: DeviceInfo,
        is_internet_resource_active: bool,
    ) -> Result<Self, ConnlibError> {
        // iOS doesn't need socket protection like Android
        let tcp_socket_factory = Arc::new(socket_factory::tcp);
        let udp_socket_factory = Arc::new(socket_factory::udp);

        let session = connect(
            api_url,
            token,
            device_id,
            account_slug,
            device_name,
            log_dir,
            log_filter,
            device_info,
            is_internet_resource_active,
            tcp_socket_factory,
            udp_socket_factory,
        )?;

        set_tun_from_search(&session)?;

        Ok(session)
    }
}

#[uniffi::export]
impl Session {
    #[uniffi::constructor]
    #[expect(
        clippy::too_many_arguments,
        reason = "This is the API we want to expose over FFI."
    )]
    /// Dummy constructor that isn't feature-gated by an OS.
    ///
    /// This only exists to make working on the FFI module from Linux/Windows more convenient without many "unused code" warnings.
    pub fn new_dummy(
        api_url: String,
        token: String,
        device_id: String,
        account_slug: String,
        device_name: Option<String>,
        log_dir: String,
        log_filter: String,
        device_info: DeviceInfo,
        is_internet_resource_active: bool,
    ) -> Result<Self, ConnlibError> {
        let tcp_socket_factory = Arc::new(socket_factory::tcp);
        let udp_socket_factory = Arc::new(socket_factory::udp);

        let session = connect(
            api_url,
            token,
            device_id,
            account_slug,
            device_name,
            log_dir,
            log_filter,
            device_info,
            is_internet_resource_active,
            tcp_socket_factory,
            udp_socket_factory,
        )?;

        Ok(session)
    }
}

/// Set up TUN device with retry logic.
///
/// Retries a few times with a small delay, as the NetworkExtension
/// might still be setting up the TUN interface.
#[cfg(any(target_os = "ios", target_os = "macos"))]
fn set_tun_from_search(session: &Session) -> Result<(), ConnlibError> {
    const MAX_TUN_SETUP_ATTEMPTS: u32 = 5;
    const TUN_SETUP_RETRY_DELAY_MS: u64 = 100;

    let runtime = session.runtime.as_ref().context("No runtime")?;

    let mut last_error = None;
    for attempt in 1..=MAX_TUN_SETUP_ATTEMPTS {
        tracing::debug!("Attempting to find TUN device (attempt {})", attempt);
        match platform::Tun::new(runtime.handle()) {
            Ok(tun) => {
                tracing::debug!("Successfully found and set TUN device");
                session.inner.set_tun(Box::new(tun));
                return Ok(());
            }
            Err(e) => {
                tracing::warn!("Attempt {} failed: {}", attempt, e);
                last_error = Some(e);
                if attempt < MAX_TUN_SETUP_ATTEMPTS {
                    std::thread::sleep(std::time::Duration::from_millis(TUN_SETUP_RETRY_DELAY_MS));
                }
            }
        }
    }

    Err(anyhow::anyhow!(
        "Failed to find TUN device after {} attempts: {}",
        MAX_TUN_SETUP_ATTEMPTS,
        last_error.map_or_else(|| "unknown error".to_string(), |e| e.to_string())
    )
    .into())
}

#[uniffi::export]
impl Session {
    pub fn disconnect(&self) {
        self.inner.stop();

        let Some(runtime) = self.runtime.as_ref() else {
            tracing::error!(
                "No tokio runtime set! This should be impossible because we only clear it on `Drop`"
            );
            return;
        };

        runtime.block_on(async {
            self.telemetry.lock().await.stop().await;
        });
    }

    pub fn set_internet_resource_state(&self, active: bool) {
        self.inner.set_internet_resource_state(active);
    }

    pub fn set_dns(&self, dns_servers: Vec<String>) {
        let dns_servers = dns_servers
            .into_iter()
            .filter_map(|server| {
                server
                    .parse()
                    .inspect_err(|e| tracing::error!(%server, "Failed to parse DNS server as IP address: {e}"))
                    .ok()
            })
            .collect();

        self.inner.set_dns(dns_servers);
    }

    pub fn reset(&self, reason: String) {
        self.inner.reset(reason)
    }

    pub fn set_log_directives(&self, directives: String) -> Result<(), ConnlibError> {
        let (_, reload_handle) = LOGGER_STATE.get().context("Logger not yet initialised")?;

        reload_handle
            .reload(&directives)
            .context("Failed to apply new directives")?;

        Ok(())
    }

    pub fn set_tun(&self, fd: RawFd) -> Result<(), ConnlibError> {
        let runtime = self.runtime.as_ref().context("No runtime")?;
        // SAFETY: FD must be open.
        let tun = unsafe {
            platform::Tun::from_fd(fd, runtime.handle()).context("Failed to create new Tun")?
        };

        self.inner.set_tun(Box::new(tun));

        Ok(())
    }

    pub async fn next_event(&self) -> Option<Event> {
        match self.events.lock().await.next().await? {
            client_shared::Event::TunInterfaceUpdated(config) => {
                let dns = config
                    .dns_by_sentinel
                    .sentinel_ips()
                    .into_iter()
                    .map(|ip| ip.to_string())
                    .collect();

                let (ipv4_routes, ipv6_routes) =
                    config
                        .routes
                        .into_iter()
                        .partition_map(|route| match route {
                            IpNetwork::V4(v4) => itertools::Either::Left(Cidr {
                                address: v4.network_address().to_string(),
                                prefix: v4.netmask(),
                            }),
                            IpNetwork::V6(v6) => itertools::Either::Left(Cidr {
                                address: v6.network_address().to_string(),
                                prefix: v6.netmask(),
                            }),
                        });

                Some(Event::TunInterfaceUpdated {
                    ipv4: config.ip.v4.to_string(),
                    ipv6: config.ip.v6.to_string(),
                    dns,
                    search_domain: config.search_domain.map(|d| d.to_string()),
                    ipv4_routes,
                    ipv6_routes,
                })
            }
            client_shared::Event::ResourcesUpdated(resources) => {
                let resources: Vec<Resource> = resources.into_iter().map(Into::into).collect();

                Some(Event::ResourcesUpdated { resources })
            }
            client_shared::Event::Disconnected(error) => Some(Event::Disconnected {
                error: Arc::new(DisconnectError(error)),
            }),
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let Some(runtime) = self.runtime.take() else {
            return;
        };

        self.inner.stop(); // Instruct the event-loop to shut down.

        runtime.block_on(async {
            self.telemetry.lock().await.stop_on_crash().await;

            // Draining the event-stream allows us to wait for the event-loop to finish its graceful shutdown.
            let drain = async { self.events.lock().await.drain().await };
            let _ = tokio::time::timeout(Duration::from_secs(1), drain).await;
        });

        runtime.shutdown_timeout(Duration::from_secs(1)); // Ensure we don't block forever on a task in the blocking pool.
    }
}

fn connect(
    api_url: String,
    token: String,
    device_id: String,
    account_slug: String,
    device_name: Option<String>,
    log_dir: String,
    log_filter: String,
    device_info: DeviceInfo,
    is_internet_resource_active: bool,
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
) -> Result<Session, ConnlibError> {
    // Convert FFI DeviceInfo to internal phoenix_channel::DeviceInfo
    let device_info = phoenix_channel::DeviceInfo {
        device_uuid: device_info.device_uuid,
        device_serial: device_info.device_serial,
        identifier_for_vendor: device_info.identifier_for_vendor,
        firebase_installation_id: device_info.firebase_installation_id,
    };
    let secret = SecretString::from(token);

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("connlib")
        .enable_all()
        .build()
        .context("Failed to create tokio runtime")?;

    let mut telemetry = Telemetry::new();
    runtime.block_on(telemetry.start(&api_url, RELEASE, platform::DSN, device_id.clone()));
    Telemetry::set_account_slug(account_slug.clone());

    analytics::identify(RELEASE.to_owned(), Some(account_slug));

    init_logging(&PathBuf::from(log_dir), log_filter)?;
    install_rustls_crypto_provider();

    let url = LoginUrl::client(
        api_url.as_str(),
        device_id.clone(),
        device_name,
        device_info,
    )
    .context("Failed to create login URL")?;

    let _guard = runtime.enter(); // Constructing `PhoenixChannel` requires a runtime context.

    let portal = PhoenixChannel::disconnected(
        url,
        secret,
        get_user_agent(platform::COMPONENT, platform::VERSION),
        "client",
        (),
        || {
            ExponentialBackoffBuilder::default()
                .with_max_elapsed_time(Some(platform::MAX_PARTITION_TIME))
                .build()
        },
        tcp_socket_factory.clone(),
    );
    let (session, events) = client_shared::Session::connect(
        tcp_socket_factory,
        udp_socket_factory,
        portal,
        is_internet_resource_active,
        Vec::default(),
        runtime.handle().clone(),
    );

    analytics::new_session(device_id, api_url.to_string());

    Ok(Session {
        inner: session,
        events: Mutex::new(events),
        telemetry: Mutex::new(telemetry),
        runtime: Some(runtime),
    })
}

static LOGGER_STATE: OnceLock<(logging::file::Handle, logging::FilterReloadHandle)> =
    OnceLock::new();

fn init_logging(log_dir: &Path, log_filter: String) -> Result<()> {
    if let Some((_, reload_handle)) = LOGGER_STATE.get() {
        reload_handle
            .reload(&log_filter)
            .context("Failed to apply new log-filter")?;
        return Ok(());
    }

    let (file_log_filter, file_reload_handle) = logging::try_filter(&log_filter)?;
    let (platform_log_filter, platform_reload_handle) = logging::try_filter(&log_filter)?;
    let (file_layer, handle) = logging::file::layer(log_dir, "connlib");

    let subscriber = tracing_subscriber::registry()
        .with(file_layer.with_filter(file_log_filter))
        .with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .event_format(logging::Format::new().without_timestamp().without_level())
                .with_writer(platform::MakeWriter::default())
                .with_filter(platform_log_filter),
        )
        .with(sentry_layer());

    let reload_handle = file_reload_handle.merge(platform_reload_handle);

    logging::init(subscriber)?;

    LOGGER_STATE
        .set((handle, reload_handle))
        .map_err(|_| anyhow!("Logging guard should never be initialized twice"))?;

    Ok(())
}

#[cfg(target_os = "android")]
fn protected_tcp_socket_factory(callback: Arc<dyn ProtectSocket>) -> impl SocketFactory<TcpSocket> {
    move |addr| {
        let socket = socket_factory::tcp(addr)?;
        use std::os::fd::AsRawFd;
        callback
            .protect_socket(socket.as_raw_fd())
            .map_err(std::io::Error::other)?;

        Ok(socket)
    }
}

#[cfg(target_os = "android")]
fn protected_udp_socket_factory(callback: Arc<dyn ProtectSocket>) -> impl SocketFactory<UdpSocket> {
    move |addr| {
        let socket = socket_factory::udp(addr)?;
        use std::os::fd::AsRawFd;
        callback
            .protect_socket(socket.as_raw_fd())
            .map_err(std::io::Error::other)?;

        Ok(socket)
    }
}

/// Installs the `ring` crypto provider for rustls.
fn install_rustls_crypto_provider() {
    let existing = rustls::crypto::ring::default_provider().install_default();

    if existing.is_err() {
        tracing::debug!("Skipping install of crypto provider because we already have one.");
    }
}

/// Enforces a size cap on log directories by deleting oldest files first.
///
/// # Returns
/// Number of bytes deleted (best-effort, never fails)
#[uniffi::export]
pub fn enforce_log_size_cap(log_dirs: Vec<String>, max_size_mb: u32) -> u64 {
    let paths: Vec<std::path::PathBuf> = log_dirs.iter().map(std::path::PathBuf::from).collect();
    let path_refs: Vec<&std::path::Path> = paths.iter().map(|p| p.as_path()).collect();

    logging::cleanup::enforce_size_cap(&path_refs, max_size_mb)
}

impl From<connlib_model::ResourceView> for Resource {
    fn from(resource: connlib_model::ResourceView) -> Self {
        match resource {
            connlib_model::ResourceView::Dns(dns) => Resource::Dns {
                resource: dns.into(),
            },
            connlib_model::ResourceView::Cidr(cidr) => Resource::Cidr {
                resource: cidr.into(),
            },
            connlib_model::ResourceView::Internet(internet) => Resource::Internet {
                resource: internet.into(),
            },
        }
    }
}

impl From<connlib_model::DnsResourceView> for DnsResource {
    fn from(dns: connlib_model::DnsResourceView) -> Self {
        DnsResource {
            id: dns.id.to_string(),
            address: dns.address,
            name: dns.name,
            address_description: dns.address_description,
            sites: dns.sites.into_iter().map(Into::into).collect(),
            status: dns.status.into(),
        }
    }
}

impl From<connlib_model::CidrResourceView> for CidrResource {
    fn from(cidr: connlib_model::CidrResourceView) -> Self {
        CidrResource {
            id: cidr.id.to_string(),
            address: cidr.address.to_string(),
            name: cidr.name,
            address_description: cidr.address_description,
            sites: cidr.sites.into_iter().map(Into::into).collect(),
            status: cidr.status.into(),
        }
    }
}

impl From<connlib_model::InternetResourceView> for InternetResource {
    fn from(internet: connlib_model::InternetResourceView) -> Self {
        InternetResource {
            id: internet.id.to_string(),
            name: internet.name,
            sites: internet.sites.into_iter().map(Into::into).collect(),
            status: internet.status.into(),
        }
    }
}

impl From<connlib_model::Site> for Site {
    fn from(site: connlib_model::Site) -> Self {
        Site {
            id: site.id.to_string(),
            name: site.name,
        }
    }
}

impl From<connlib_model::ResourceStatus> for ResourceStatus {
    fn from(status: connlib_model::ResourceStatus) -> Self {
        match status {
            connlib_model::ResourceStatus::Unknown => ResourceStatus::Unknown,
            connlib_model::ResourceStatus::Online => ResourceStatus::Online,
            connlib_model::ResourceStatus::Offline => ResourceStatus::Offline,
        }
    }
}

impl From<anyhow::Error> for ConnlibError {
    fn from(value: anyhow::Error) -> Self {
        Self(value)
    }
}

impl From<uniffi::UnexpectedUniFFICallbackError> for CallbackError {
    fn from(value: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed(format!("Callback failed: {}", value.reason))
    }
}
