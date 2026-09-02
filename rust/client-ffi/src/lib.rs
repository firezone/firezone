// Not on iOS: the Network Extension has a hard memory cap and mimalloc retains freed pages, which
// risks a jetsam kill. The system allocator is tuned for that budget, so we keep it there.
#[cfg(not(target_os = "ios"))]
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod client_identity;
mod fd;
mod platform;

// Links the `x509claims` UniFFI scaffolding into `libconnlib`, so that one Rust
// library serves both namespaces. A binary can only carry a single Rust staticlib
// without duplicating the runtime, so the bindings ship inside `libconnlib` instead
// of a second library.
use x509claims as _;

use crate::fd::RawFd;

use std::{
    fmt,
    path::PathBuf,
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
use telemetry::analytics;
use tokio::sync::Mutex;
use tracing_subscriber::{Layer, layer::SubscriberExt as _};

uniffi::setup_scaffolding!();

#[derive(uniffi::Object)]
pub struct Session {
    inner: client_shared::Session,
    events: Mutex<client_shared::EventStream>,
    runtime: Option<tokio::runtime::Runtime>,
    uploader: Option<flow_log_upload::Uploader>,
}

#[derive(uniffi::Object, thiserror::Error, Debug)]
#[error("{0:#}")]
pub struct ConnlibError(anyhow::Error);

#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum CallbackError {
    #[error("{0}")]
    Failed(String),
}

/// The TLS handshake signature schemes a platform-held key can sign with.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum TlsSignatureScheme {
    RsaPkcs1Sha256,
    RsaPkcs1Sha384,
    RsaPkcs1Sha512,
    RsaPssSha256,
    RsaPssSha384,
    RsaPssSha512,
    EcdsaNistp256Sha256,
    EcdsaNistp384Sha384,
    EcdsaNistp521Sha512,
}

/// A certificate chain and a non-exportable platform key, presented to the portal for mutual TLS.
///
/// The key material stays in the platform keystore, so we ask it for a signature whenever the TLS handshake needs one.
#[uniffi::export(with_foreign)]
pub trait ClientTlsIdentity: Send + Sync + fmt::Debug {
    /// Returns the DER-encoded certificate chain, end-entity certificate first.
    fn certificate_chain(&self) -> Result<Vec<Vec<u8>>, CallbackError>;

    /// Returns the signature schemes the key can sign with, most preferred first.
    ///
    /// All of them must belong to the same key algorithm.
    ///
    /// # Errors
    ///
    /// Returns an error if the keystore cannot be consulted.
    fn supported_signature_schemes(&self) -> Result<Vec<TlsSignatureScheme>, CallbackError>;

    /// Signs the unhashed TLS handshake message with the requested scheme.
    fn sign(&self, scheme: TlsSignatureScheme, message: Vec<u8>) -> Result<Vec<u8>, CallbackError>;
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

/// Configuration for constructing an Android session.
///
/// Passing one record across the FFI boundary avoids JNA's arm64 calling-convention issues with
/// constructors that have many by-value `RustBuffer` arguments.
#[derive(uniffi::Record)]
pub struct AndroidSessionConfig {
    pub api_url: String,
    pub token: Option<String>,
    pub device_id: String,
    pub device_name: String,
    pub device_info: DeviceInfo,
    pub is_internet_resource_active: bool,
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

/// A device peer that this client currently has a live connection to.
#[derive(uniffi::Record)]
pub struct ConnectedDevice {
    pub id: String,
    /// Name assigned to the connected client.
    pub name: String,
    /// Tunnel IPv4 address the device is reachable on.
    pub tun_ipv4: String,
    /// Tunnel IPv6 address the device is reachable on.
    pub tun_ipv6: String,
    /// Names of the device pools this peer belongs to, sorted (typically one,
    /// but can be multiple).
    pub pools: Vec<String>,
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
        connected_devices: Vec<ConnectedDevice>,
    },
    ConnectedToPortal {
        account_slug: String,
        actor_name: String,
    },
    AllGatewaysOffline {
        resource_id: String,
    },
    GatewayVersionMismatch {
        resource_id: String,
    },
    Disconnected {
        error: Arc<DisconnectError>,
    },
}

#[uniffi::export]
impl ConnlibError {
    /// Renders the error and its source chain.
    ///
    /// UniFFI maps this type to an opaque foreign class, so the `Display` impl is
    /// not otherwise reachable from the bindings.
    pub fn message(&self) -> String {
        self.to_string()
    }
}

#[uniffi::export]
impl DisconnectError {
    pub fn message(&self) -> String {
        self.0.to_string()
    }

    /// Returns whether the stored token must be discarded and the user sent through sign-in again.
    ///
    /// This does not report whether the failure was authentication-related in general.
    /// Only failures that render the token itself unusable require a new sign-in.
    pub fn requires_sign_in(&self) -> bool {
        self.0.requires_sign_in()
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
    pub fn new_android(
        config: AndroidSessionConfig,
        protect_socket: Arc<dyn ProtectSocket>,
        tls_identity: Option<Arc<dyn ClientTlsIdentity>>,
    ) -> Result<Self, ConnlibError> {
        let AndroidSessionConfig {
            api_url,
            token,
            device_id,
            device_name,
            device_info,
            is_internet_resource_active,
        } = config;
        let udp_socket_factory = Arc::new(protected_udp_socket_factory(protect_socket.clone()));
        let tcp_socket_factory = Arc::new(protected_tcp_socket_factory(protect_socket));

        connect(
            api_url,
            token,
            device_id,
            Some(device_name),
            device_info,
            is_internet_resource_active,
            tls_identity,
            tcp_socket_factory,
            udp_socket_factory,
        )
    }
}

#[uniffi::export]
#[cfg(any(target_os = "ios", target_os = "macos"))]
impl Session {
    #[uniffi::constructor]
    pub fn new_apple(
        api_url: String,
        token: Option<String>,
        device_id: String,
        device_name: Option<String>,
        device_info: DeviceInfo,
        is_internet_resource_active: bool,
        tls_identity: Option<Arc<dyn ClientTlsIdentity>>,
    ) -> Result<Self, ConnlibError> {
        // iOS doesn't need socket protection like Android
        let tcp_socket_factory = Arc::new(socket_factory::tcp);
        let udp_socket_factory = Arc::new(socket_factory::udp);

        // Locate the TUN device before `connect` spawns anything: every failed
        // search used to leave a Tokio runtime and its threads behind, and the
        // NetworkExtension process outlives the session that owns them.
        let tun_fd = find_tun_fd()?;

        let session = connect(
            api_url,
            token,
            device_id,
            device_name,
            device_info,
            is_internet_resource_active,
            tls_identity,
            tcp_socket_factory,
            udp_socket_factory,
        )?;

        session.set_tun(tun_fd)?;

        Ok(session)
    }
}

#[uniffi::export]
impl Session {
    #[uniffi::constructor]
    /// Dummy constructor that isn't feature-gated by an OS.
    ///
    /// This only exists to make working on the FFI module from Linux/Windows more convenient without many "unused code" warnings.
    pub fn new_dummy(
        api_url: String,
        token: Option<String>,
        device_id: String,
        device_name: Option<String>,
        device_info: DeviceInfo,
        is_internet_resource_active: bool,
        tls_identity: Option<Arc<dyn ClientTlsIdentity>>,
    ) -> Result<Self, ConnlibError> {
        let tcp_socket_factory = Arc::new(socket_factory::tcp);
        let udp_socket_factory = Arc::new(socket_factory::udp);

        let session = connect(
            api_url,
            token,
            device_id,
            device_name,
            device_info,
            is_internet_resource_active,
            tls_identity,
            tcp_socket_factory,
            udp_socket_factory,
        )?;

        Ok(session)
    }
}

/// Find the TUN device with retry logic.
///
/// Retries a few times with a small delay, as the NetworkExtension
/// might still be setting up the TUN interface.
#[cfg(any(target_os = "ios", target_os = "macos"))]
fn find_tun_fd() -> Result<RawFd, ConnlibError> {
    const MAX_TUN_SETUP_ATTEMPTS: u32 = 5;
    const TUN_SETUP_RETRY_DELAY_MS: u64 = 100;

    let mut last_error = None;
    for attempt in 1..=MAX_TUN_SETUP_ATTEMPTS {
        tracing::debug!(attempt, "Attempting to find TUN device");
        match platform::search_fd() {
            Ok(fd) => {
                tracing::debug!("Successfully found TUN device");
                return Ok(fd);
            }
            Err(e) => {
                tracing::debug!(attempt, error = %e, "Failed to find TUN device");
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
                            IpNetwork::V6(v6) => itertools::Either::Right(Cidr {
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
            client_shared::Event::ResourcesUpdated(resource_list) => {
                let resources = resource_list
                    .resources
                    .into_iter()
                    .map(Into::into)
                    .collect();
                let connected_devices = resource_list
                    .connected_devices
                    .into_iter()
                    .map(Into::into)
                    .collect();

                Some(Event::ResourcesUpdated {
                    resources,
                    connected_devices,
                })
            }
            client_shared::Event::ConnectedToPortal(connected) => {
                telemetry::set_account_slug(connected.account_slug.clone());

                analytics::identify(
                    RELEASE.to_owned(),
                    connected.account_slug.clone(),
                    None,
                    None,
                );

                Some(Event::ConnectedToPortal {
                    account_slug: connected.account_slug,
                    actor_name: connected.actor_name,
                })
            }
            client_shared::Event::AllGatewaysOffline { resource_id } => {
                Some(Event::AllGatewaysOffline {
                    resource_id: resource_id.to_string(),
                })
            }
            client_shared::Event::GatewayVersionMismatch { resource_id } => {
                Some(Event::GatewayVersionMismatch {
                    resource_id: resource_id.to_string(),
                })
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
            // Draining the event-stream allows us to wait for the event-loop to finish its graceful shutdown.
            let drain = async { self.events.lock().await.drain().await };
            let _ = tokio::time::timeout(Duration::from_secs(1), drain).await;
        });

        runtime.shutdown_timeout(Duration::from_secs(1)); // Ensure we don't block forever on a task in the blocking pool.

        // The event loop spooled its open flows on the way out; flush them.
        if let Some(uploader) = self.uploader.take() {
            // The app process outlives the session; don't delay the disconnect.
            #[cfg(target_os = "android")]
            let flush = None;
            // The provider may be reaped right after `stopTunnel`; wait.
            #[cfg(not(target_os = "android"))]
            let flush = Some(FLOW_LOG_DRAIN_TIMEOUT);

            uploader.nudge();
            uploader.stop(flush);
        }
    }
}

fn connect(
    api_url: String,
    token: Option<String>,
    device_id: String,
    device_name: Option<String>,
    device_info: DeviceInfo,
    is_internet_resource_active: bool,
    tls_identity: Option<Arc<dyn ClientTlsIdentity>>,
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
    let token = token
        .map(SecretString::from)
        .ok_or_else(|| anyhow!("Cannot authenticate without a token"))?;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("connlib")
        .enable_all()
        .build()
        .context("Failed to create tokio runtime")?;

    install_rustls_crypto_provider();

    // Fail loudly rather than run a session with no logs and no flow-log spool.
    let flow_logs_dir = LOGGER
        .get()
        .context("Logger must be configured before connecting")?
        .flow_log_guard
        .as_ref()
        .map(|guard| guard.spool_root().to_path_buf());

    tunnel_bypass_resolver::configure(tcp_socket_factory.clone(), udp_socket_factory.clone());

    telemetry::start(&api_url, RELEASE, platform::DSN);
    telemetry::set_firezone_id(device_id.clone());
    // The portal names the account in `init`; until then this session has none.
    telemetry::set_account_slug(None);

    analytics::identify(RELEASE.to_owned(), None, None, None);

    let certificate = tls_identity
        .map(client_identity::certificate)
        .transpose()
        .context("Failed to set up the client certificate")?;

    let url = LoginUrl::client(
        api_url.as_str(),
        device_id.clone(),
        device_name,
        device_info,
        certificate,
    )
    .context("Failed to create login URL")?;

    let _guard = runtime.enter(); // Constructing `PhoenixChannel` requires a runtime context.

    let portal = PhoenixChannel::disconnected(
        url,
        Some(token),
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
    // The uploader lives and dies with the session (idle, it would only poll
    // and dial); registered so `drain_flow_logs` nudges it instead of racing it.
    let uploader = flow_logs_dir.clone().map(|dir| {
        let uploader = flow_log_upload::spawn(dir, tcp_socket_factory.clone());

        *lock_uploader() = Some(uploader.clone());

        uploader
    });

    let (session, events) = client_shared::Session::connect(
        tcp_socket_factory,
        udp_socket_factory,
        portal,
        is_internet_resource_active,
        Vec::default(),
        flow_logs_dir,
        false,
        runtime.handle().clone(),
    );

    analytics::new_session(device_id, api_url);

    Ok(Session {
        inner: session,
        events: Mutex::new(events),
        runtime: Some(runtime),
        uploader,
    })
}

fn start_telemetry_inner(tcp: Arc<dyn SocketFactory<TcpSocket>>) {
    install_rustls_crypto_provider();

    telemetry::configure(tcp);
    telemetry::start("entrypoint", RELEASE, platform::DSN);

    opentelemetry::global::set_meter_provider(telemetry::SentryMeterProvider::default());
}

#[uniffi::export]
#[cfg(target_os = "android")]
pub fn start_telemetry(protect_socket: Arc<dyn ProtectSocket>) {
    let tcp = Arc::new(protected_tcp_socket_factory(protect_socket));

    start_telemetry_inner(tcp);
}

#[uniffi::export]
#[cfg(not(target_os = "android"))]
pub fn start_telemetry() {
    start_telemetry_inner(Arc::new(socket_factory::tcp));
}

#[uniffi::export]
pub fn stop_telemetry() {
    telemetry::stop();
}

/// The process-wide logger, installed once by [`configure_logger`].
struct Logger {
    reload_handle: logging::FilterReloadHandle,
    /// Owns the flow-log spool root, so the uploader can be pointed at the same
    /// place the writer uses rather than told separately.
    flow_log_guard: Option<flow_log_writer::Guard>,
    _file_handle: logging::file::Handle,
}

static LOGGER: OnceLock<Logger> = OnceLock::new();

/// Installs the logger, or re-applies `log_filter` when it is already installed.
///
/// A session is not the only thing that logs: the network extension is woken
/// without one to drain flow logs, and every event emitted before this runs is
/// dropped. So every entry point configures the logger itself, and [`connect`]
/// requires that to have happened already: it reads the flow-log spool root back
/// off the installed logger rather than being told it a second time.
///
/// Only `log_filter` is re-applied. The directories stay whichever the first
/// call passed, so callers must agree on them.
#[uniffi::export]
pub fn configure_logger(
    log_dir: String,
    log_filter: String,
    flow_logs_dir: Option<String>,
) -> Result<(), ConnlibError> {
    if let Some(logger) = LOGGER.get() {
        logger
            .reload_handle
            .reload(&log_filter)
            .context("Failed to apply new log-filter")?;
        return Ok(());
    }

    let (file_log_filter, file_reload_handle) =
        logging::try_filter(&log_filter).context("Failed to parse log filter")?;
    let (platform_log_filter, platform_reload_handle) =
        logging::try_filter(&log_filter).context("Failed to parse log filter")?;
    let (file_layer, handle) = logging::file::layer(&PathBuf::from(log_dir), "connlib");
    // Spools flow-log reports for the uploader, like the desktop entrypoints do.
    let (flow_log_layer, flow_log_guard) = flow_logs_dir
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .map(flow_log_writer::layer)
        .unzip();

    let subscriber = tracing_subscriber::registry()
        .with(file_layer.with_filter(file_log_filter))
        .with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .event_format(logging::Format::new().without_timestamp().without_level())
                .with_writer(platform::MakeWriter::default())
                .with_filter(platform_log_filter),
        )
        .with(flow_log_layer)
        .with(sentry_layer());

    let reload_handle = file_reload_handle.merge(platform_reload_handle);

    logging::init(subscriber)?;

    LOGGER
        .set(Logger {
            reload_handle,
            flow_log_guard,
            _file_handle: handle,
        })
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
            .map_err(socket_factory::RoutingLoopPreventionFailed::new)?;

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
            .map_err(socket_factory::RoutingLoopPreventionFailed::new)?;

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

/// Default maximum total log size in MB across all log directories.
#[uniffi::export]
pub fn log_cleanup_default_max_size_mb() -> u32 {
    logging::DEFAULT_MAX_SIZE_MB
}

/// Default interval between log cleanup runs in seconds (1 hour).
#[uniffi::export]
pub fn log_cleanup_default_interval_secs() -> u64 {
    logging::DEFAULT_CLEANUP_INTERVAL.as_secs()
}

/// Hashes a device ID using SHA256 and returns the hex-encoded result.
///
/// This is exposed via FFI so that clients an produce
/// the exact same hash as connlib, without reimplementing the algorithm.
#[uniffi::export]
pub fn hash_device_id(id: String) -> String {
    telemetry::hash_device_id(id)
}

/// Drains the flow-log spool at `spool_dir`, e.g. on app foreground or launch.
///
/// Nudges a live session's uploader and returns; without one, runs a one-shot
/// pass, blocking for it up to [`FLOW_LOG_DRAIN_TIMEOUT`]. Sockets always use
/// the platform's tunnel bypass (Apple's NE sockets are excluded, Android
/// `protect()`s each one), so a drain can never loop through a tunnel.
#[uniffi::export]
#[cfg(target_os = "android")]
pub fn drain_flow_logs(spool_dir: String, protect_socket: Arc<dyn ProtectSocket>) {
    do_drain_flow_logs(
        spool_dir,
        Arc::new(protected_tcp_socket_factory(protect_socket)),
    );
}

#[uniffi::export]
#[cfg(not(target_os = "android"))]
pub fn drain_flow_logs(spool_dir: String) {
    do_drain_flow_logs(spool_dir, Arc::new(socket_factory::tcp));
}

fn do_drain_flow_logs(spool_dir: String, tcp: Arc<dyn SocketFactory<TcpSocket>>) {
    install_rustls_crypto_provider();

    let mut uploader = lock_uploader();

    if let Some(uploader) = uploader.as_ref()
        && uploader.nudge()
    {
        return;
    }

    let one_shot = flow_log_upload::spawn(PathBuf::from(spool_dir), tcp);
    *uploader = Some(one_shot.clone());
    drop(uploader);

    // Wait outside the registry lock so a concurrent `connect` isn't blocked.
    one_shot.stop(Some(FLOW_LOG_DRAIN_TIMEOUT));
}

/// Longest a drain blocks (one-shot and session-drop flush); well within the
/// 15-30s the OS grants `stopTunnel` on Apple.
const FLOW_LOG_DRAIN_TIMEOUT: Duration = Duration::from_secs(10);

/// The one live uploader thread: the session's, else the latest one-shot.
/// Serializes drains.
static UPLOADER: std::sync::Mutex<Option<flow_log_upload::Uploader>> = std::sync::Mutex::new(None);

fn lock_uploader() -> std::sync::MutexGuard<'static, Option<flow_log_upload::Uploader>> {
    UPLOADER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Returns whether log streaming is currently active.
#[uniffi::export]
pub fn is_log_streaming_active() -> bool {
    telemetry::feature_flags::stream_logs_active()
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

impl From<connlib_model::ConnectedDeviceView> for ConnectedDevice {
    fn from(device: connlib_model::ConnectedDeviceView) -> Self {
        ConnectedDevice {
            id: device.id.to_string(),
            name: device.name,
            tun_ipv4: device.tun_ipv4.to_string(),
            tun_ipv6: device.tun_ipv6.to_string(),
            pools: device.pools,
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
