// Swift bridge generated code triggers this below
#![allow(clippy::unnecessary_cast, improper_ctypes, non_camel_case_types)]

use connlib_client_shared::{file_logger, Callbacks, Error, ResourceDescription, Session};
use ip_network::IpNetwork;
use secrecy::SecretString;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tracing_subscriber::prelude::*;
use tracing_subscriber::EnvFilter;

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

        #[swift_bridge(associated_to = WrappedSession)]
        fn connect(
            api_url: String,
            token: String,
            device_id: String,
            device_name_override: Option<String>,
            os_version_override: Option<String>,
            log_dir: String,
            log_filter: String,
            callback_handler: CallbackHandler,
        ) -> Result<WrappedSession, String>;

        fn disconnect(&mut self);
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

        #[swift_bridge(swift_name = "onTunnelReady")]
        fn on_tunnel_ready(&self);

        #[swift_bridge(swift_name = "onAddRoute")]
        fn on_add_route(&self, route: String);

        #[swift_bridge(swift_name = "onRemoveRoute")]
        fn on_remove_route(&self, route: String);

        #[swift_bridge(swift_name = "onUpdateResources")]
        fn on_update_resources(&self, resourceList: String);

        #[swift_bridge(swift_name = "onDisconnect")]
        fn on_disconnect(&self, error: String);

        #[swift_bridge(swift_name = "getSystemDefaultResolvers")]
        fn get_system_default_resolvers(&self) -> String;
    }
}

/// This is used by the apple client to interact with our code.
pub struct WrappedSession(Session<CallbackHandler>);

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
    handle: file_logger::Handle,
}

impl Callbacks for CallbackHandler {
    type Error = std::convert::Infallible;

    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_addresses: Vec<IpAddr>,
    ) -> Result<Option<RawFd>, Self::Error> {
        self.inner.on_set_interface_config(
            tunnel_address_v4.to_string(),
            tunnel_address_v6.to_string(),
            serde_json::to_string(&dns_addresses)
                .expect("developer error: a list of ips should always be serializable"),
        );
        Ok(None)
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        self.inner.on_tunnel_ready();
        Ok(())
    }

    fn on_add_route(&self, route: IpNetwork) -> Result<Option<RawFd>, Self::Error> {
        self.inner.on_add_route(route.to_string());
        Ok(None)
    }

    fn on_remove_route(&self, route: IpNetwork) -> Result<Option<RawFd>, Self::Error> {
        self.inner.on_remove_route(route.to_string());
        Ok(None)
    }

    fn on_update_resources(
        &self,
        resource_list: Vec<ResourceDescription>,
    ) -> Result<(), Self::Error> {
        self.inner.on_update_resources(
            serde_json::to_string(&resource_list)
                .expect("developer error: failed to serialize resource list"),
        );
        Ok(())
    }

    fn on_disconnect(&self, error: Option<&Error>) -> Result<(), Self::Error> {
        self.inner
            .on_disconnect(error.map(ToString::to_string).unwrap_or_default());
        Ok(())
    }

    fn get_system_default_resolvers(&self) -> Result<Option<Vec<IpAddr>>, Self::Error> {
        let resolvers_json = self.inner.get_system_default_resolvers();
        tracing::debug!(
            "get_system_default_resolvers returned: {:?}",
            resolvers_json
        );

        let resolvers: Vec<IpAddr> = serde_json::from_str(&resolvers_json)
            .expect("developer error: failed to deserialize resolvers");
        Ok(Some(resolvers))
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.handle.roll_to_new_file().unwrap_or_else(|e| {
            tracing::error!("Failed to roll over to new log file: {e}");
            None
        })
    }
}

fn init_logging(log_dir: PathBuf, log_filter: String) -> file_logger::Handle {
    let (file_layer, handle) = file_logger::layer(&log_dir);

    let _ = tracing_subscriber::registry()
        .with(
            tracing_oslog::OsLogger::new("dev.firezone.firezone", "connlib")
                .with_filter(EnvFilter::new(log_filter.clone())),
        )
        .with(file_layer.with_filter(EnvFilter::new(log_filter)))
        .try_init();

    handle
}

impl WrappedSession {
    // TODO: Refactor this when we refactor PhoenixChannel.
    // See https://github.com/firezone/firezone/issues/2158
    #[allow(clippy::too_many_arguments)]
    fn connect(
        api_url: String,
        token: String,
        device_id: String,
        device_name_override: Option<String>,
        os_version_override: Option<String>,
        log_dir: String,
        log_filter: String,
        callback_handler: ffi::CallbackHandler,
    ) -> Result<Self, String> {
        let secret = SecretString::from(token);

        let session = Session::connect(
            api_url.as_str(),
            secret,
            device_id,
            device_name_override,
            os_version_override,
            CallbackHandler {
                inner: Arc::new(callback_handler),
                handle: init_logging(log_dir.into(), log_filter),
            },
            Some(MAX_PARTITION_TIME),
        )
        .map_err(|err| err.to_string())?;

        Ok(Self(session))
    }

    fn disconnect(&mut self) {
        self.0.disconnect()
    }
}
