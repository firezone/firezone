#![cfg(any(target_os = "macos", target_os = "ios"))]
// Swift bridge generated code triggers this below
#![allow(improper_ctypes, non_camel_case_types)]

use firezone_client_connlib::{Callbacks, Error, ResourceDescription, Session};
use ip_network::IpNetwork;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    sync::Arc,
};

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        type WrappedSession;

        #[swift_bridge(associated_to = WrappedSession)]
        fn connect(
            portal_url: String,
            token: String,
            external_id: String,
            callback_handler: CallbackHandler,
        ) -> Result<WrappedSession, String>;

        #[swift_bridge(swift_name = "bumpSockets")]
        fn bump_sockets(&self);

        #[swift_bridge(swift_name = "disableSomeRoamingForBrokenMobileSemantics")]
        fn disable_some_roaming_for_broken_mobile_semantics(&self);

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

fn init_logging() {
    use tracing_subscriber::layer::SubscriberExt as _;
    let collector = tracing_subscriber::registry().with(tracing_oslog::OsLogger::new(
        "dev.firezone.firezone",
        "connlib",
    ));
    // This will fail if called more than once, but that doesn't really matter.
    if tracing::subscriber::set_global_default(collector).is_ok() {
        tracing::debug!("subscribed to logging");
    }
}

impl WrappedSession {
    fn connect(
        portal_url: String,
        token: String,
        external_id: String,
        callback_handler: ffi::CallbackHandler,
    ) -> Result<Self, String> {
        init_logging();
        Session::connect(
            portal_url.as_str(),
            token,
            external_id,
            CallbackHandler(callback_handler.into()),
        )
        .map(|session| Self { session })
        .map_err(|err| err.to_string())
    }

    fn bump_sockets(&self) {
        self.session.bump_sockets()
    }

    fn disable_some_roaming_for_broken_mobile_semantics(&self) {
        self.session
            .disable_some_roaming_for_broken_mobile_semantics()
    }

    fn disconnect(&mut self) {
        self.session.disconnect(None)
    }
}
