// Swift bridge generated code triggers this below
#![allow(improper_ctypes)]
#![cfg(any(target_os = "macos", target_os = "ios"))]

use firezone_client_connlib::{
    Callbacks, Error, ErrorType, ResourceList, Session, SwiftConnlibError, SwiftErrorType,
    TunnelAddresses,
};

#[swift_bridge::bridge]
mod ffi {
    #[swift_bridge(swift_repr = "struct")]
    struct ResourceList {
        resources: String,
    }

    // TODO: Allegedly not FFI safe, but works
    #[swift_bridge(swift_repr = "struct")]
    struct TunnelAddresses {
        address4: String,
        address6: String,
    }

    #[swift_bridge(already_declared)]
    enum SwiftConnlibError {}

    #[swift_bridge(already_declared)]
    enum SwiftErrorType {}

    extern "Rust" {
        type WrappedSession;

        #[swift_bridge(associated_to = WrappedSession)]
        fn connect(portal_url: String, token: String) -> Result<WrappedSession, SwiftConnlibError>;

        #[swift_bridge(swift_name = "bumpSockets")]
        fn bump_sockets(&self) -> bool;

        #[swift_bridge(swift_name = "disableSomeRoamingForBrokenMobileSemantics")]
        fn disable_some_roaming_for_broken_mobile_semantics(&self) -> bool;

        fn disconnect(&mut self) -> bool;
    }

    extern "Swift" {
        type Opaque;
        #[swift_bridge(swift_name = "onUpdateResources")]
        fn on_update_resources(resourceList: ResourceList);

        #[swift_bridge(swift_name = "onSetTunnelAddresses")]
        fn on_set_tunnel_addresses(tunnelAddresses: TunnelAddresses);

        #[swift_bridge(swift_name = "onError")]
        fn on_error(error: SwiftConnlibError, error_type: SwiftErrorType);
    }
}

impl From<ResourceList> for ffi::ResourceList {
    fn from(value: ResourceList) -> Self {
        Self {
            resources: value.resources.join(","),
        }
    }
}

impl From<TunnelAddresses> for ffi::TunnelAddresses {
    fn from(value: TunnelAddresses) -> Self {
        Self {
            address4: value.address4.to_string(),
            address6: value.address6.to_string(),
        }
    }
}

/// This is used by the apple client to interact with our code.
pub struct WrappedSession {
    session: Session<CallbackHandler>,
}

struct CallbackHandler;

impl Callbacks for CallbackHandler {
    fn on_update_resources(resource_list: ResourceList) {
        ffi::on_update_resources(resource_list.into());
    }

    fn on_set_tunnel_adresses(tunnel_addresses: TunnelAddresses) {
        ffi::on_set_tunnel_addresses(tunnel_addresses.into());
    }

    fn on_error(error: &Error, error_type: ErrorType) {
        ffi::on_error(error.into(), error_type.into());
    }
}

impl WrappedSession {
    fn connect(portal_url: String, token: String) -> Result<Self, SwiftConnlibError> {
        let session = Session::connect::<CallbackHandler>(portal_url.as_str(), token)?;
        Ok(Self { session })
    }

    fn bump_sockets(&self) -> bool {
        // TODO: See https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKitGo/api-apple.go#L177
        todo!()
    }

    fn disable_some_roaming_for_broken_mobile_semantics(&self) -> bool {
        // TODO: See https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKitGo/api-apple.go#LL197C6-L197C50
        todo!()
    }

    fn disconnect(&mut self) -> bool {
        self.session.disconnect()
    }
}
