// The "system" ABI is only needed for Java FFI on Win32, not Android:
// https://github.com/jni-rs/jni-rs/pull/22
// However, this consideration has made it idiomatic for Java FFI in the Rust
// ecosystem, so it's used here for consistency.

use firezone_client_connlib::{Callbacks, Error, ResourceList, Session, TunnelAddresses};
use jni::{
    objects::{JClass, JObject, JString, JValue},
    JNIEnv,
};
use std::net::Ipv4Addr;

/// This should be called once after the library is loaded by the system.
#[allow(non_snake_case)]
#[no_mangle]
pub extern "system" fn Java_dev_firezone_connlib_Logger_init(_: JNIEnv, _: JClass) {
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(if cfg!(debug_assertions) {
                log::LevelFilter::Trace
            } else {
                log::LevelFilter::Warn
            })
            .with_tag("connlib"),
    )
}

#[derive(Clone)]
pub struct CallbackHandler;

impl Callbacks for CallbackHandler {
    fn on_set_interface_config(&self, _tunnel_addresses: TunnelAddresses, _dns_address: Ipv4Addr) {
        todo!()
    }

    fn on_tunnel_ready(&self) {
        todo!()
    }

    fn on_add_route(&self, _route: String) {
        todo!()
    }

    fn on_remove_route(&self, _route: String) {
        todo!()
    }

    fn on_update_resources(&self, _resource_list: ResourceList) {
        todo!()
    }

    fn on_disconnect(&self, _error: Option<&Error>) {
        todo!()
    }

    fn on_error(&self, _error: &Error) {
        todo!()
    }
}

/// # Safety
/// Pointers must be valid
#[allow(non_snake_case)]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_connlib_Session_connect(
    mut env: JNIEnv,
    _class: JClass,
    portal_url: JString,
    portal_token: JString,
    callback: JObject,
) -> *const Session<CallbackHandler> {
    let portal_url: String = env.get_string(&portal_url).unwrap().into();
    let portal_token: String = env.get_string(&portal_token).unwrap().into();

    let session = Box::new(
        Session::connect(portal_url.as_str(), portal_token, CallbackHandler).expect("TODO!"),
    );

    // TODO: Get actual IPs returned from portal based on this device
    let tunnelAddressesJSON = "[{\"tunnel_ipv4\": \"100.100.1.1\", \"tunnel_ipv6\": \"fd00:0222:2011:1111:6def:1001:fe67:0012\"}]";
    let tunnel_addresses = env.new_string(tunnelAddressesJSON).unwrap();
    match env.call_method(
        callback,
        "onTunnelReady",
        "(Ljava/lang/String;)Z",
        &[JValue::from(&tunnel_addresses)],
    ) {
        Ok(res) => log::trace!("`onTunnelReady` returned `{res:?}`"),
        Err(err) => log::error!("Failed to call `onTunnelReady`: {err}"),
    }

    Box::into_raw(session)
}

/// # Safety
/// Pointers must be valid
#[allow(non_snake_case)]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_connlib_Session_disconnect(
    _env: JNIEnv,
    _: JClass,
    session_ptr: *mut Session<CallbackHandler>,
) -> bool {
    if session_ptr.is_null() {
        return false;
    }

    let session = unsafe { &mut *session_ptr };
    session.disconnect(None)
}

/// # Safety
/// Pointers must be valid
#[allow(non_snake_case)]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_connlib_Session_bump_sockets(
    session_ptr: *const Session<CallbackHandler>,
) -> bool {
    if session_ptr.is_null() {
        return false;
    }

    unsafe { (*session_ptr).bump_sockets() };

    // TODO: See https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKitGo/api-apple.go#LL197C6-L197C50
    true
}

/// # Safety
/// Pointers must be valid
#[allow(non_snake_case)]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_connlib_disable_some_roaming_for_broken_mobile_semantics(
    session_ptr: *const Session<CallbackHandler>,
) -> bool {
    if session_ptr.is_null() {
        return false;
    }

    unsafe { (*session_ptr).disable_some_roaming_for_broken_mobile_semantics() };

    // TODO: See https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKitGo/api-apple.go#LL197C6-L197C50
    true
}
