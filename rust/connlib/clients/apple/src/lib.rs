// Swift bridge generated code triggers this below
#![allow(clippy::unnecessary_cast, improper_ctypes, non_camel_case_types)]

mod make_writer;
mod tun;

use anyhow::Context;
use anyhow::Result;
use backoff::ExponentialBackoffBuilder;
use connlib_client_shared::{Callbacks, DisconnectError, Session, V4RouteList, V6RouteList};
use connlib_model::ResourceView;
use firezone_logging::anyhow_dyn_err;
use firezone_telemetry::Telemetry;
use firezone_telemetry::APPLE_DSN;
use ip_network::{Ipv4Network, Ipv6Network};
use phoenix_channel::get_user_agent;
use phoenix_channel::LoginUrl;
use phoenix_channel::PhoenixChannel;
use secrecy::{Secret, SecretString};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::runtime::Runtime;
use tracing_subscriber::{prelude::*, util::TryInitError};
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

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        type WrappedSession;

        #[swift_bridge(associated_to = WrappedSession, return_with = err_to_string)]
        fn connect(
            api_url: String,
            token: String,
            device_id: String,
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
        );

        #[swift_bridge(swift_name = "onUpdateRoutes")]
        fn on_update_routes(&self, routeList4: String, routeList6: String);

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

    #[expect(
        dead_code,
        reason = "Logger handle must be kept alive until Session is dropped"
    )]
    logger: firezone_logging::file::Handle,

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
    ) {
        self.inner.on_set_interface_config(
            tunnel_address_v4.to_string(),
            tunnel_address_v6.to_string(),
            serde_json::to_string(&dns_addresses)
                .expect("developer error: a list of ips should always be serializable"),
        );
    }

    fn on_update_routes(&self, route_list_4: Vec<Ipv4Network>, route_list_6: Vec<Ipv6Network>) {
        self.inner.on_update_routes(
            serde_json::to_string(&V4RouteList::new(route_list_4)).unwrap(),
            serde_json::to_string(&V6RouteList::new(route_list_6)).unwrap(),
        );
    }

    fn on_update_resources(&self, resource_list: Vec<ResourceView>) {
        self.inner.on_update_resources(
            serde_json::to_string(&resource_list)
                .expect("developer error: failed to serialize resource list"),
        );
    }

    fn on_disconnect(&self, error: &DisconnectError) {
        self.inner.on_disconnect(error.to_string());
    }
}

fn init_logging(
    log_dir: PathBuf,
    log_filter: String,
) -> Result<firezone_logging::file::Handle, TryInitError> {
    let (file_layer, handle) = firezone_logging::file::layer(&log_dir);

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .event_format(
                    firezone_logging::Format::new()
                        .without_ansi()
                        .without_timestamp()
                        .without_level(),
                )
                .with_writer(make_writer::MakeWriter::new(
                    "dev.firezone.firezone",
                    "connlib",
                )),
        )
        .with(file_layer)
        .with(firezone_logging::filter(&log_filter))
        .try_init()?;

    Ok(handle)
}

impl WrappedSession {
    // TODO: Refactor this when we refactor PhoenixChannel.
    // See https://github.com/firezone/firezone/issues/2158
    #[expect(clippy::too_many_arguments)]
    fn connect(
        api_url: String,
        token: String,
        device_id: String,
        device_name_override: Option<String>,
        os_version_override: Option<String>,
        log_dir: String,
        log_filter: String,
        callback_handler: ffi::CallbackHandler,
        device_info: String,
    ) -> Result<Self> {
        let mut telemetry = Telemetry::default();
        telemetry.start(&api_url, env!("CARGO_PKG_VERSION"), APPLE_DSN);
        telemetry.set_firezone_id(device_id.clone());

        let logger = init_logging(log_dir.into(), log_filter)?;
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
            ExponentialBackoffBuilder::default()
                .with_max_elapsed_time(Some(MAX_PARTITION_TIME))
                .build(),
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
            logger,
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
        tracing::error!(error = anyhow_dyn_err(&e), "Failed to create session");

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
