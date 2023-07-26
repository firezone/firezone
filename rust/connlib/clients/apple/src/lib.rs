#![cfg(any(target_os = "macos", target_os = "ios"))]
// Swift bridge generated code triggers this below
#![allow(improper_ctypes, non_camel_case_types)]

use firezone_client_connlib::{Callbacks, Error, ResourceDescription, Session, TunnelAddresses};
use std::{net::Ipv4Addr, sync::Arc};

#[swift_bridge::bridge]
mod ffi {
    #[swift_bridge(swift_repr = "struct")]
    struct TunnelAddresses {
        address4: String,
        address6: String,
    }

    // TODO: Duplicating these enum variants from `libs/common/src/error.rs` is
    // brittle/noisy/tedious
    enum SwiftConnlibError {
        // `swift-bridge` doesn't seem to support `Option` for Swift function
        None,
        Io { description: String, value: usize },
        Base64DecodeError { value: u32, description: String },
        Base64DecodeSliceError { description: String },
        RequestError { description: String },
        PortalConnectionError { description: String },
        UriError { description: String },
        SerializeError { description: String },
        IceError { description: String },
        IceDataError { description: String },
        SendChannelError { description: String },
        ConnectionEstablishError { description: String },
        WireguardError { description: String },
        NoRuntime { description: String },
        UnknownResource { description: String },
        ControlProtocolError { description: String },
        IfaceRead { description: String },
        Other { description: String },
        InvalidTunnelName { description: String },
        NetlinkErrorIo { description: String },
        NoIface { description: String },
        NoMtu { description: String },
        Panic(String),
        PanicNonStringPayload { description: String },
    }

    extern "Rust" {
        type WrappedSession;

        #[swift_bridge(associated_to = WrappedSession)]
        fn connect(
            portal_url: String,
            token: String,
            callback_handler: CallbackHandler,
        ) -> Result<WrappedSession, SwiftConnlibError>;

        #[swift_bridge(swift_name = "bumpSockets")]
        fn bump_sockets(&self) -> bool;

        #[swift_bridge(swift_name = "disableSomeRoamingForBrokenMobileSemantics")]
        fn disable_some_roaming_for_broken_mobile_semantics(&self) -> bool;

        fn disconnect(&mut self) -> bool;
    }

    extern "Swift" {
        type CallbackHandler;

        #[swift_bridge(swift_name = "onSetInterfaceConfig")]
        fn on_set_interface_config(&self, tunnelAddresses: TunnelAddresses, dnsAddress: String);

        #[swift_bridge(swift_name = "onTunnelReady")]
        fn on_tunnel_ready(&self);

        #[swift_bridge(swift_name = "onAddRoute")]
        fn on_add_route(&self, route: String);

        #[swift_bridge(swift_name = "onRemoveRoute")]
        fn on_remove_route(&self, route: String);

        #[swift_bridge(swift_name = "onUpdateResources")]
        fn on_update_resources(&self, resourceList: String);

        #[swift_bridge(swift_name = "onDisconnect")]
        fn on_disconnect(&self, error: SwiftConnlibError);

        #[swift_bridge(swift_name = "onError")]
        fn on_error(&self, error: SwiftConnlibError);
    }
}

impl<'a> From<&'a Error> for ffi::SwiftConnlibError {
    fn from(val: &'a Error) -> Self {
        match val {
            Error::Io(..) => Self::Io,
            Error::Base64DecodeError(..) => Self::Base64DecodeError,
            Error::Base64DecodeSliceError(..) => Self::Base64DecodeSliceError,
            Error::RequestError(..) => Self::RequestError,
            Error::PortalConnectionError(..) => Self::PortalConnectionError,
            Error::UriError => Self::UriError,
            Error::SerializeError(..) => Self::SerializeError,
            Error::IceError(..) => Self::IceError,
            Error::IceDataError(..) => Self::IceDataError,
            Error::SendChannelError => Self::SendChannelError,
            Error::ConnectionEstablishError => Self::ConnectionEstablishError,
            Error::WireguardError(..) => Self::WireguardError,
            Error::NoRuntime => Self::NoRuntime,
            Error::UnknownResource => Self::UnknownResource,
            Error::ControlProtocolError => Self::ControlProtocolError,
            Error::IfaceRead(..) => Self::IfaceRead,
            Error::Other(..) => Self::Other,
            Error::InvalidTunnelName => Self::InvalidTunnelName,
            Error::NetlinkErrorIo(_) => Self::NetlinkErrorIo,
            Error::NoIface => Self::NoIface,
            Error::NoMtu => Self::NoMtu,
            Error::Panic(msg) => Self::Panic(msg.into()),
            Error::PanicNonStringPayload => Self::PanicNonStringPayload,
        }
    }
}

impl From<Error> for ffi::SwiftConnlibError {
    fn from(val: Error) -> Self {
        (&val).into()
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
    fn on_set_interface_config(&self, tunnel_addresses: TunnelAddresses, dns_address: Ipv4Addr) {
        self.0
            .on_set_interface_config(tunnel_addresses.into(), dns_address.to_string())
    }

    fn on_tunnel_ready(&self) {
        self.0.on_tunnel_ready()
    }

    fn on_add_route(&self, route: String) {
        self.0.on_add_route(route)
    }

    fn on_remove_route(&self, route: String) {
        self.0.on_remove_route(route)
    }

    fn on_update_resources(&self, resource_list: Vec<ResourceDescription>) {
        self.0.on_update_resources(
            serde_json::to_string(&resource_list)
                .expect("developer error: failed to serialize resource list"),
        )
    }

    fn on_disconnect(&self, error: Option<&Error>) {
        self.0.on_disconnect(
            error
                .map(Into::into)
                .unwrap_or(ffi::SwiftConnlibError::None),
        )
    }

    fn on_error(&self, error: &Error) {
        self.0.on_error(error.into())
    }
}

impl WrappedSession {
    fn connect(
        portal_url: String,
        token: String,
        callback_handler: ffi::CallbackHandler,
    ) -> Result<Self, ffi::SwiftConnlibError> {
        Ok(Self {
            session: Session::connect(
                portal_url.as_str(),
                token,
                CallbackHandler(callback_handler.into()),
            )?,
        })
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
        self.session.disconnect(None)
    }
}
