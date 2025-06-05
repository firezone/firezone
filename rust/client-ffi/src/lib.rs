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
use platform::{DSN, MAX_PARTITION_TIME, MakeWriter, RELEASE, VERSION};
use secrecy::{Secret, SecretString};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use tracing_subscriber::layer::SubscriberExt as _;

uniffi::setup_scaffolding!();

#[derive(uniffi::Object)]
pub struct Session {
    inner: client_shared::Session,
    telemetry: Telemetry,
    runtime: tokio::runtime::Runtime,
}

#[derive(uniffi::Object, thiserror::Error, Debug)]
#[error("{0:#}")]
pub struct Error(anyhow::Error);

#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum CallbackError {}

#[derive(uniffi::Object, Debug)]
pub struct DisconnectError(client_shared::DisconnectError);

#[uniffi::export]
impl DisconnectError {
    #[expect(
        clippy::inherent_to_string,
        reason = "This is the API we want to expose over FFI."
    )]
    pub fn to_string(&self) -> String {
        self.0.to_string()
    }

    pub fn is_authentication_error(&self) -> bool {
        self.0.is_authentication_error()
    }
}

#[uniffi::export(with_foreign)]
pub trait Callbacks: Send + Sync + fmt::Debug {
    fn on_set_interface_config(
        &self,
        tunnel_address_ipv4: String,
        tunnel_address_ipv6: String,
        search_domain: Option<String>,
        dns_addresses: String,
        route_listv4: String,
        route_listv6: String,
    ) -> Result<(), CallbackError>;

    fn on_update_resources(&self, resource_list: String) -> Result<(), CallbackError>;

    fn on_disconnect(&self, error: Arc<DisconnectError>) -> Result<(), CallbackError>;
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
        callbacks: Arc<dyn Callbacks>,
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
            callbacks,
            tcp_socket_factory,
            udp_socket_factory,
        )
    }

    pub fn disconnect(&self) -> Result<(), Error> {
        todo!()
    }

    pub fn set_disabled_resources(&self, disabled_resources: String) -> Result<(), Error> {
        todo!()
    }

    pub fn set_dns(&self, dns_servers: String) -> Result<(), Error> {
        todo!()
    }

    pub fn reset(&self) -> Result<(), Error> {
        todo!()
    }

    pub fn set_log_directives(&self, directives: String) -> Result<(), Error> {
        todo!()
    }

    pub fn set_tun(&self, fd: RawFd) -> Result<(), Error> {
        todo!()
    }
}

macro_rules! try_serialize {
    ($res: expr) => {
        match $res {
            Ok(v) => v,
            Err(e) => {
                tracing::error!("Failed to serialize: {e}");
                continue;
            }
        }
    };
}

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
    callbacks: Arc<dyn Callbacks>,
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
) -> Result<Session, Error> {
    let device_info =
        serde_json::from_str(&device_info).context("Failed to deserialize `DeviceInfo`")?;
    let secret = SecretString::from(token);

    let mut telemetry = Telemetry::default();
    telemetry.start(&api_url, RELEASE, platform::DSN);
    Telemetry::set_firezone_id(device_id.clone());

    analytics::identify(device_id.clone(), api_url.to_string(), RELEASE.to_owned());

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
    let (session, mut event_stream) = client_shared::Session::connect(
        tcp_socket_factory,
        udp_socket_factory,
        portal,
        runtime.handle().clone(),
    );

    analytics::new_session(device_id, api_url.to_string());

    runtime.spawn(async move {
        while let Some(event) = event_stream.next().await {
            let result = match event {
                client_shared::Event::TunInterfaceUpdated {
                    ipv4,
                    ipv6,
                    dns,
                    search_domain,
                    ipv4_routes,
                    ipv6_routes,
                } => {
                    let dns = try_serialize!(serde_json::to_string(&dns));
                    let ipv4_routes =
                        try_serialize!(serde_json::to_string(&V4RouteList::new(ipv4_routes)));
                    let ipv6_routes =
                        try_serialize!(serde_json::to_string(&V6RouteList::new(ipv6_routes)));

                    callbacks.on_set_interface_config(
                        ipv4.to_string(),
                        ipv6.to_string(),
                        search_domain.map(|d| d.to_string()),
                        dns,
                        ipv4_routes,
                        ipv6_routes,
                    )
                }
                client_shared::Event::ResourcesUpdated(resource_views) => {
                    let resource_views = try_serialize!(serde_json::to_string(&resource_views));

                    callbacks.on_update_resources(resource_views)
                }
                client_shared::Event::Disconnected(error) => {
                    callbacks.on_disconnect(Arc::new(DisconnectError(error)))
                }
            };

            if let Err(e) = result {
                tracing::error!("Callback failed: {e}")
            }
        }
    });

    Ok(Session {
        inner: session,
        telemetry,
        runtime,
    })
}

fn init_logging(log_dir: &Path, log_filter: String) -> Result<()> {
    static LOGGER_STATE: OnceLock<(
        firezone_logging::file::Handle,
        firezone_logging::FilterReloadHandle,
    )> = OnceLock::new();
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
