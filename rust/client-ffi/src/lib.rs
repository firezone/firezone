mod platform;

use std::{
    fmt, io,
    os::fd::{AsRawFd as _, RawFd},
    path::{Path, PathBuf},
    sync::{Arc, OnceLock},
};

use anyhow::{Context as _, Result};
use backoff::ExponentialBackoffBuilder;
use client_shared::{V4RouteList, V6RouteList};
use firezone_logging::sentry_layer;
use firezone_telemetry::{Telemetry, analytics};
use phoenix_channel::{LoginUrl, PhoenixChannel, get_user_agent};
use platform::RELEASE;
use secrecy::{Secret, SecretString};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use tokio::sync::Mutex;
use tracing_subscriber::layer::SubscriberExt as _;

uniffi::setup_scaffolding!();

#[derive(uniffi::Object)]
pub struct Session {
    inner: client_shared::Session,
    events: Mutex<client_shared::EventStream>,
    telemetry: Mutex<Telemetry>,
    runtime: tokio::runtime::Runtime,
}

#[derive(uniffi::Object, thiserror::Error, Debug)]
#[error("{0:#}")]
pub struct Error(anyhow::Error);

#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum CallbackError {
    #[error("{0}")]
    Failed(String),
}

#[derive(uniffi::Object, Debug)]
pub struct DisconnectError(client_shared::DisconnectError);

#[derive(uniffi::Enum)]
pub enum Event {
    TunInterfaceUpdated {
        ipv4: String,
        ipv6: String,
        dns: String,
        search_domain: Option<String>,
        ipv4_routes: String,
        ipv6_routes: String,
    },
    ResourcesUpdated {
        resources: String,
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
        os_version: String,
        log_dir: String,
        log_filter: String,
        device_info: String,
        protect_socket: Arc<dyn ProtectSocket>,
    ) -> Result<Self, Error> {
        let udp_socket_factory = Arc::new(protected_udp_socket_factory(protect_socket.clone()));
        let tcp_socket_factory = Arc::new(protected_tcp_socket_factory(protect_socket));

        connect(
            api_url,
            token,
            device_id,
            account_slug,
            Some(device_name),
            Some(os_version),
            log_dir,
            log_filter,
            device_info,
            tcp_socket_factory,
            udp_socket_factory,
        )
    }

    pub fn disconnect(&self) {
        self.runtime.block_on(async {
            self.telemetry.lock().await.stop().await;
        });
        self.inner.stop();
    }

    pub fn set_disabled_resources(&self, disabled_resources: String) -> Result<(), Error> {
        let disabled_resources = serde_json::from_str(&disabled_resources)
            .context("Failed to deserialize disabled resource IDs")?;

        self.inner.set_disabled_resources(disabled_resources);

        Ok(())
    }

    pub fn set_dns(&self, dns_servers: String) -> Result<(), Error> {
        let dns_servers =
            serde_json::from_str(&dns_servers).context("Failed to deserialize DNS servers")?;

        self.inner.set_dns(dns_servers);

        Ok(())
    }

    pub fn reset(&self) {
        self.inner.reset()
    }

    pub fn set_log_directives(&self, directives: String) -> Result<(), Error> {
        let (_, reload_handle) = LOGGER_STATE.get().context("Logger not yet initialised")?;

        reload_handle
            .reload(&directives)
            .context("Failed to apply new directives")?;

        Ok(())
    }

    pub fn set_tun(&self, fd: RawFd) -> Result<(), Error> {
        let _guard = self.runtime.enter();
        // SAFETY: FD must be open.
        let tun = unsafe { platform::Tun::from_fd(fd).context("Failed to create new Tun")? };

        self.inner.set_tun(Box::new(tun));

        Ok(())
    }

    pub async fn next_event(&self) -> Result<Option<Event>, Error> {
        match self.events.lock().await.next().await {
            Some(client_shared::Event::TunInterfaceUpdated {
                ipv4,
                ipv6,
                dns,
                search_domain,
                ipv4_routes,
                ipv6_routes,
            }) => {
                let dns = serde_json::to_string(&dns).context("Failed to serialize DNS servers")?;
                let ipv4_routes = serde_json::to_string(&V4RouteList::new(ipv4_routes))
                    .context("Failed to serialize IPv4 routes")?;
                let ipv6_routes = serde_json::to_string(&V6RouteList::new(ipv6_routes))
                    .context("Failed to serialize IPv6 routes")?;

                Ok(Some(Event::TunInterfaceUpdated {
                    ipv4: ipv4.to_string(),
                    ipv6: ipv6.to_string(),
                    dns,
                    search_domain: search_domain.map(|d| d.to_string()),
                    ipv4_routes,
                    ipv6_routes,
                }))
            }
            Some(client_shared::Event::ResourcesUpdated(resources)) => {
                let resources = serde_json::to_string(&resources)
                    .context("Failed to serialize resource list")?;

                Ok(Some(Event::ResourcesUpdated { resources }))
            }
            Some(client_shared::Event::Disconnected(error)) => Ok(Some(Event::Disconnected {
                error: Arc::new(DisconnectError(error)),
            })),
            None => Ok(None),
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.runtime
            .block_on(async { self.telemetry.lock().await.stop_on_crash().await })
    }
}

#[expect(clippy::too_many_arguments, reason = "We don't care.")]
fn connect(
    api_url: String,
    token: String,
    device_id: String,
    account_slug: String,
    device_name: Option<String>,
    os_version: Option<String>,
    log_dir: String,
    log_filter: String,
    device_info: String,
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
) -> Result<Session, Error> {
    let device_info =
        serde_json::from_str(&device_info).context("Failed to deserialize `DeviceInfo`")?;
    let secret = SecretString::from(token);

    let mut telemetry = Telemetry::default();
    telemetry.start(&api_url, RELEASE, platform::DSN);
    Telemetry::set_firezone_id(device_id.clone());
    Telemetry::set_account_slug(account_slug.clone());

    analytics::identify(
        device_id.clone(),
        api_url.to_string(),
        RELEASE.to_owned(),
        Some(account_slug),
    );

    init_logging(&PathBuf::from(log_dir), log_filter)?;
    install_rustls_crypto_provider();

    let url = LoginUrl::client(
        api_url.as_str(),
        &secret,
        device_id.clone(),
        device_name,
        device_info,
    )
    .context("Failed to create login URL")?;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("connlib")
        .enable_all()
        .build()
        .context("Failed to create tokio runtime")?;
    let _guard = runtime.enter(); // Constructing `PhoenixChannel` requires a runtime context.

    let portal = PhoenixChannel::disconnected(
        Secret::new(url),
        get_user_agent(os_version, platform::VERSION),
        "client",
        (),
        || {
            ExponentialBackoffBuilder::default()
                .with_max_elapsed_time(Some(platform::MAX_PARTITION_TIME))
                .build()
        },
        tcp_socket_factory.clone(),
    )
    .context("Failed to create `PhoenixChannel`")?;
    let (session, events) = client_shared::Session::connect(
        tcp_socket_factory,
        udp_socket_factory,
        portal,
        runtime.handle().clone(),
    );

    analytics::new_session(device_id, api_url.to_string());

    Ok(Session {
        inner: session,
        events: Mutex::new(events),
        telemetry: Mutex::new(telemetry),
        runtime,
    })
}

static LOGGER_STATE: OnceLock<(
    firezone_logging::file::Handle,
    firezone_logging::FilterReloadHandle,
)> = OnceLock::new();

fn init_logging(log_dir: &Path, log_filter: String) -> Result<()> {
    if let Some((_, reload_handle)) = LOGGER_STATE.get() {
        reload_handle
            .reload(&log_filter)
            .context("Failed to apply new log-filter")?;
        return Ok(());
    }

    let (log_filter, reload_handle) = firezone_logging::try_filter(&log_filter)?;
    let (file_layer, handle) = firezone_logging::file::layer(log_dir, "connlib");

    let subscriber = tracing_subscriber::registry()
        .with(log_filter)
        .with(file_layer)
        .with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .event_format(
                    firezone_logging::Format::new()
                        .without_timestamp()
                        .without_level(),
                )
                .with_writer(platform::MakeWriter::default()),
        )
        .with(sentry_layer());

    firezone_logging::init(subscriber)?;

    LOGGER_STATE
        .set((handle, reload_handle))
        .expect("Logging guard should never be initialized twice");

    Ok(())
}

fn protected_tcp_socket_factory(callback: Arc<dyn ProtectSocket>) -> impl SocketFactory<TcpSocket> {
    move |addr| {
        let socket = socket_factory::tcp(addr)?;
        callback
            .protect_socket(socket.as_raw_fd())
            .map_err(io::Error::other)?;

        Ok(socket)
    }
}

fn protected_udp_socket_factory(callback: Arc<dyn ProtectSocket>) -> impl SocketFactory<UdpSocket> {
    move |addr| {
        let socket = socket_factory::udp(addr)?;
        callback
            .protect_socket(socket.as_raw_fd())
            .map_err(io::Error::other)?;

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

impl From<anyhow::Error> for Error {
    fn from(value: anyhow::Error) -> Self {
        Self(value)
    }
}

impl From<uniffi::UnexpectedUniFFICallbackError> for CallbackError {
    fn from(value: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed(format!("Callback failed: {}", value.reason))
    }
}
