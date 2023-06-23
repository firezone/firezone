#[macro_use]
extern crate log;
extern crate android_logger;
extern crate jni;
use self::jni::JNIEnv;
use android_logger::Config;
use firezone_client_connlib::{
    Callbacks, Error, ErrorType, ResourceList, Session, TunnelAddresses,
};
use jni::objects::{JClass, JObject, JString, JValue};
use log::LevelFilter;

/// This should be called once after the library is loaded by the system.
#[allow(non_snake_case)]
#[no_mangle]
pub extern "system" fn Java_dev_firezone_connlib_Logger_init(_: JNIEnv, _: JClass) {
    #[cfg(debug_assertions)]
    let level = LevelFilter::Trace;
    #[cfg(not(debug_assertions))]
    let level = LevelFilter::Warn;

    android_logger::init_once(
        Config::default()
            // Allow all log levels
            .with_max_level(level)
            .with_tag("connlib"),
    )
}

pub enum CallbackHandler {}
impl Callbacks for CallbackHandler {
    fn on_update_resources(_resource_list: ResourceList) {
        todo!()
    }

    fn on_set_tunnel_adresses(_tunnel_addresses: TunnelAddresses) {
        todo!()
    }

    fn on_error(_error: &Error, _error_type: ErrorType) {
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
        Session::connect::<CallbackHandler>(portal_url.as_str(), portal_token).expect("TODO!"),
    );

    // TODO: Get actual IPs returned from portal based on this device
    let tunnelAddressesJSON = "[{\"tunnel_ipv4\": \"100.100.1.1\", \"tunnel_ipv6\": \"fd00:0222:2011:1111:6def:1001:fe67:0012\"}]";
    let tunnel_addresses = env.new_string(tunnelAddressesJSON).unwrap();
    match env.call_method(
        callback,
        "onSetTunnelAddresses",
        "(Ljava/lang/String;)Z",
        &[JValue::from(&tunnel_addresses)],
    ) {
        Ok(res) => trace!("onSetTunnelAddresses returned {:?}", res),
        Err(e) => error!("Failed to call setTunnelAddresses: {:?}", e),
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
    session.disconnect()
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
