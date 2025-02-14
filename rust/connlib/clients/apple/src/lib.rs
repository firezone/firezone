// Swift bridge generated code triggers this below
#![allow(clippy::unnecessary_cast, improper_ctypes, non_camel_case_types)]
#![cfg(unix)]

mod make_writer;
mod tun;

use anyhow::Context;
use anyhow::Result;
use backoff::ExponentialBackoffBuilder;
use connlib_client_shared::{Callbacks, DisconnectError, Session, V4RouteList, V6RouteList};
use connlib_model::ResourceView;
use firezone_logging::err_with_src;
use firezone_telemetry::Telemetry;
use firezone_telemetry::APPLE_DSN;
use ip_network::{Ipv4Network, Ipv6Network};
use phoenix_channel::get_user_agent;
use phoenix_channel::LoginUrl;
use phoenix_channel::PhoenixChannel;
use secrecy::{Secret, SecretString};
use std::sync::OnceLock;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::runtime::Runtime;
use tracing_subscriber::prelude::*;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::Registry;
use tun::Tun;

/// The Apple client implements reconnect logic in the upper layer using OS provided
/// APIs to detect network connectivity changes. The reconnect timeout here only
/// applies only in the following conditions:
///
/// * That reconnect logic fails to detect network changes (not expected to happen)
/// * The portal is DOWN
///
/// Hopefully we aren't down for more than 24 hours.
const MAX_PARTITION_TIME: Duration = Duration::from_secs(60 * 60 * 24);

/// The Sentry release.
///
/// This module is only responsible for the connlib part of the MacOS/iOS app.
/// Bugs within the MacOS/iOS app itself may use the same DSN but a different component as part of the version string.
const RELEASE: &str = concat!("connlib-apple@", env!("CARGO_PKG_VERSION"));

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        type WrappedSession;

        #[swift_bridge(associated_to = WrappedSession, return_with = err_to_string)]
        fn connect(
            api_url: String,
            token: String,
            device_id: String,
            account_slug: String,
            device_name_override: Option<String>,
            os_version_override: Option<String>,
            log_dir: String,
            log_filter: String,
            callback_handler: CallbackHandler,
            device_info: String,
        ) -> Result<WrappedSession, String>;

        fn reset(&mut self);

        // Set system DNS resolvers
        //
        // `dns_servers` must not have any IPv6 scopes
        // <https://github.com/firezone/firezone/issues/4350>
        #[swift_bridge(swift_name = "setDns")]
        fn set_dns(&mut self, dns_servers: String);

        #[swift_bridge(swift_name = "setDisabledResources")]
        fn set_disabled_resources(&mut self, disabled_resources: String);
        fn disconnect(self);
    }

    extern "Swift" {
        type CallbackHandler;

        #[swift_bridge(swift_name = "onSetInterfaceConfig")]
        fn on_set_interface_config(
            &self,
            tunnelAddressIPv4: String,
            tunnelAddressIPv6: String,
            dnsAddresses: String,
            routeListv4: String,
            routeListv6: String,
        );

        #[swift_bridge(swift_name = "onUpdateResources")]
        fn on_update_resources(&self, resourceList: String);

        #[swift_bridge(swift_name = "onDisconnect")]
        fn on_disconnect(&self, error: String);
    }
}

/// This is used by the apple client to interact with our code.
pub struct WrappedSession {
    inner: Session,
    runtime: Runtime,

    telemetry: Telemetry,
}

// SAFETY: `CallbackHandler.swift` promises to be thread-safe.
// TODO: Uphold that promise!
unsafe impl Send for ffi::CallbackHandler {}
unsafe impl Sync for ffi::CallbackHandler {}

#[derive(Clone)]
pub struct CallbackHandler {
    // Generated Swift opaque type wrappers have a `Drop` impl that decrements the
    // refcount, but there's no way to generate a `Clone` impl that increments the
    // recount. Instead, we just wrap it in an `Arc`.
    inner: Arc<ffi::CallbackHandler>,
}

impl Callbacks for CallbackHandler {
    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_addresses: Vec<IpAddr>,
        route_list_v4: Vec<Ipv4Network>,
        route_list_v6: Vec<Ipv6Network>,
    ) {
        match (
            serde_json::to_string(&dns_addresses),
            serde_json::to_string(&V4RouteList::new(route_list_v4)),
            serde_json::to_string(&V6RouteList::new(route_list_v6)),
        ) {
            (Ok(dns_addresses), Ok(route_list_4), Ok(route_list_6)) => {
                self.inner.on_set_interface_config(
                    tunnel_address_v4.to_string(),
                    tunnel_address_v6.to_string(),
                    dns_addresses,
                    route_list_4,
                    route_list_6,
                );
            }
            (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => {
                tracing::error!("Failed to serialize to JSON: {}", err_with_src(&e));
            }
        }
    }

    fn on_update_resources(&self, resource_list: Vec<ResourceView>) {
        let resource_list = match serde_json::to_string(&resource_list) {
            Ok(resource_list) => resource_list,
            Err(e) => {
                tracing::error!("Failed to serialize resource list: {}", err_with_src(&e));
                return;
            }
        };

        self.inner.on_update_resources(resource_list);
    }

    fn on_disconnect(&self, error: DisconnectError) {
        self.inner.on_disconnect(error.to_string());
    }
}

/// Initialises a global logger with the specified log filter.
///
/// A global logger can only be set once, hence this function uses `static` state to check whether a logger has already been set.
/// If so, the new `log_filter` will be applied to the existing logger but a different `log_dir` won't have any effect.
///
/// From within the FFI module, we have no control over our memory lifecycle and we may get initialised multiple times within the same process.
fn init_logging(log_dir: PathBuf, log_filter: String) -> Result<()> {
    static LOGGER_STATE: OnceLock<(
        firezone_logging::file::Handle,
        tracing_subscriber::reload::Handle<EnvFilter, Registry>,
    )> = OnceLock::new();

    let env_filter =
        firezone_logging::try_filter(&log_filter).context("Failed to parse log-filter")?;

    if let Some((_, reload_handle)) = LOGGER_STATE.get() {
        reload_handle
            .reload(env_filter)
            .context("Failed to apply new log-filter")?;

        return Ok(());
    }

    let (env_filter, reload_handle) = tracing_subscriber::reload::Layer::new(env_filter);

    let (file_layer, handle) = firezone_logging::file::layer(&log_dir, "connlib");

    let subscriber = tracing_subscriber::registry()
        .with(env_filter)
        .with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .event_format(
                    firezone_logging::Format::new()
                        .without_timestamp()
                        .without_level(),
                )
                .with_writer(make_writer::MakeWriter::new(
                    "dev.firezone.firezone",
                    "connlib",
                )),
        )
        .with(file_layer);

    firezone_logging::init(subscriber)?;

    LOGGER_STATE
        .set((handle, reload_handle))
        .expect("logger state should only ever be initialised once");

    Ok(())
}

impl WrappedSession {
    // TODO: Refactor this when we refactor PhoenixChannel.
    // See https://github.com/firezone/firezone/issues/2158
    #[expect(clippy::too_many_arguments)]
    fn connect(
        api_url: String,
        token: String,
        device_id: String,
        account_slug: String,
        device_name_override: Option<String>,
        os_version_override: Option<String>,
        log_dir: String,
        log_filter: String,
        callback_handler: ffi::CallbackHandler,
        device_info: String,
    ) -> Result<Self> {
        let mut telemetry = Telemetry::default();
        telemetry.start(&api_url, RELEASE, APPLE_DSN);
        telemetry.set_firezone_id(device_id.clone());
        telemetry.set_account_slug(account_slug);

        init_logging(log_dir.into(), log_filter)?;
        install_rustls_crypto_provider();

        let secret = SecretString::from(token);
        let device_info =
            serde_json::from_str(&device_info).context("Failed to deserialize `DeviceInfo`")?;

        let url = LoginUrl::client(
            api_url.as_str(),
            &secret,
            device_id,
            device_name_override,
            device_info,
        )?;

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("connlib")
            .enable_all()
            .build()?;
        let _guard = runtime.enter(); // Constructing `PhoenixChannel` requires a runtime context.

        let portal = PhoenixChannel::disconnected(
            Secret::new(url),
            get_user_agent(os_version_override, env!("CARGO_PKG_VERSION")),
            "client",
            (),
            || {
                ExponentialBackoffBuilder::default()
                    .with_max_elapsed_time(Some(MAX_PARTITION_TIME))
                    .build()
            },
            Arc::new(socket_factory::tcp),
        )?;
        let session = Session::connect(
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
            CallbackHandler {
                inner: Arc::new(callback_handler),
            },
            portal,
            runtime.handle().clone(),
        );
        session.set_tun(Box::new(Tun::new()?));

        Ok(Self {
            inner: session,
            runtime,
            telemetry,
        })
    }

    fn reset(&mut self) {
        self.inner.reset()
    }

    fn set_dns(&mut self, dns_servers: String) {
        let dns_servers =
            serde_json::from_str(&dns_servers).expect("Failed to deserialize DNS servers");

        self.inner.set_dns(dns_servers)
    }

    fn set_disabled_resources(&mut self, disabled_resources: String) {
        let disabled_resources = serde_json::from_str(&disabled_resources)
            .expect("Failed to deserialize disabled resources");

        self.inner.set_disabled_resources(disabled_resources)
    }

    fn disconnect(mut self) {
        self.runtime.block_on(self.telemetry.stop());
        self.inner.disconnect();
    }
}

fn err_to_string(result: Result<WrappedSession>) -> Result<WrappedSession, String> {
    result.map_err(|e| {
        tracing::error!("Failed to create session: {e:#}");

        format!("{e:#}")
    })
}

/// Installs the `ring` crypto provider for rustls.
fn install_rustls_crypto_provider() {
    let existing = rustls::crypto::ring::default_provider().install_default();

    if existing.is_err() {
        // On Apple platforms, network extensions get terminated on disconnect and thus all memory is free'd.
        // Therefore, this should not never happen unless the above is somehow no longer true.
        tracing::warn!("Skipping install of crypto provider because we already have one.");
    }
}
