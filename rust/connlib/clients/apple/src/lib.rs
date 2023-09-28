// Swift bridge generated code triggers this below
#![allow(improper_ctypes, non_camel_case_types)]

use firezone_client_connlib::{file_logger, Callbacks, Error, ResourceDescription, Session};
use ip_network::IpNetwork;
use secrecy::SecretString;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    path::PathBuf,
    sync::Arc,
};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::prelude::*;
use tracing_subscriber::EnvFilter;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        type WrappedSession;

        #[swift_bridge(associated_to = WrappedSession)]
        fn connect(
            portal_url: String,
            token: String,
            device_id: String,
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
            dnsAddress: String,
            dnsFallbackStrategy: String,
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

        #[swift_bridge(swift_name = "onError")]
        fn on_error(&self, error: String);
    }
}

/// This is used by the apple client to interact with our code.
pub struct WrappedSession {
    session: Session<CallbackHandler>,
    _guard: WorkerGuard,
}

// SAFETY: `CallbackHandler.swift` promises to be thread-safe.
// TODO: Uphold that promise!
unsafe impl Send for ffi::CallbackHandler {}
unsafe impl Sync for ffi::CallbackHandler {}

#[derive(Clone)]
#[repr(transparent)]
// Generated Swift opaque type wrappers have a `Drop` impl that decrements the
// refcount, but there's no way to generate a `Clone` impl that increments the
// recount. Instead, we just wrap it in an `Arc`.
pub struct CallbackHandler(Arc<ffi::CallbackHandler>);

impl Callbacks for CallbackHandler {
    type Error = std::convert::Infallible;

    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_address: Ipv4Addr,
        dns_fallback_strategy: String,
    ) -> Result<RawFd, Self::Error> {
        self.0.on_set_interface_config(
            tunnel_address_v4.to_string(),
            tunnel_address_v6.to_string(),
            dns_address.to_string(),
            dns_fallback_strategy.to_string(),
        );
        Ok(-1)
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        self.0.on_tunnel_ready();
        Ok(())
    }

    fn on_add_route(&self, route: IpNetwork) -> Result<(), Self::Error> {
        self.0.on_add_route(route.to_string());
        Ok(())
    }

    fn on_remove_route(&self, route: IpNetwork) -> Result<(), Self::Error> {
        self.0.on_remove_route(route.to_string());
        Ok(())
    }

    fn on_update_resources(
        &self,
        resource_list: Vec<ResourceDescription>,
    ) -> Result<(), Self::Error> {
        self.0.on_update_resources(
            serde_json::to_string(&resource_list)
                .expect("developer error: failed to serialize resource list"),
        );
        Ok(())
    }

    fn on_disconnect(&self, error: Option<&Error>) -> Result<(), Self::Error> {
        self.0
            .on_disconnect(error.map(ToString::to_string).unwrap_or_default());
        Ok(())
    }

    fn on_error(&self, error: &Error) -> Result<(), Self::Error> {
        self.0.on_error(error.to_string());
        Ok(())
    }
}

fn init_logging(log_dir: PathBuf, log_filter: String) -> WorkerGuard {
    let (file_layer, guard) = file_logger::layer(log_dir.clone());

    let _ = tracing_subscriber::registry()
        .with(tracing_oslog::OsLogger::new(
            "dev.firezone.firezone",
            "connlib",
        ))
        .with(file_layer.with_filter(EnvFilter::new(log_filter)))
        .try_init();

    guard
}

impl WrappedSession {
    fn connect(
        portal_url: String,
        token: String,
        device_id: String,
        log_dir: String,
        log_filter: String,
        callback_handler: ffi::CallbackHandler,
    ) -> Result<Self, String> {
        let _guard = init_logging(log_dir.into(), log_filter);
        let secret = SecretString::from(token);

        let session = Session::connect(
            portal_url.as_str(),
            secret,
            device_id,
            CallbackHandler(callback_handler.into()),
        )
        .map_err(|err| err.to_string())?;

        Ok(Self { session, _guard })
    }

    fn disconnect(&mut self) {
        self.session.disconnect(None)
    }
}
