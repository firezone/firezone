// The "system" ABI is only needed for Java FFI on Win32, not Android:
// https://github.com/jni-rs/jni-rs/pull/22
// However, this consideration has made it idiomatic for Java FFI in the Rust
// ecosystem, so it's used here for consistency.

use firezone_client_connlib::{Callbacks, Error, ResourceDescription, Session};
use jni::{
    objects::{JClass, JObject, JString, JValue},
    JNIEnv, JavaVM,
};
use std::net::{Ipv4Addr, Ipv6Addr};

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

pub struct CallbackHandler {
    vm: JavaVM,
    callback_handler: JObject<'static>,
}

impl Clone for CallbackHandler {
    fn clone(&self) -> Self {
        // This is essentially a `memcpy` to bypass redundant checks from
        // doing `as_raw` -> `from_raw`/etc; both of these fields are just
        // dumb pointers but the wrappers don't implement `Clone`.
        //
        // SAFETY: `self` is guaranteed to be valid and `Self` is POD.
        unsafe { std::ptr::read(self) }
    }
}

impl CallbackHandler {
    fn env<T>(&self, f: impl FnOnce(JNIEnv) -> T) -> T {
        f(self.vm.attach_current_thread_as_daemon().unwrap())
    }
}

fn call_method(env: &mut JNIEnv, this: &JObject, name: &str, sig: &str, args: &[JValue]) {
    match env.call_method(this, name, sig, args) {
        Ok(val) => log::trace!("`{name}` returned `{val:?}`"),
        Err(err) => log::error!("Failed to call `{name}`: {err}"),
    }
}

impl Callbacks for CallbackHandler {
    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_address: Ipv4Addr,
    ) {
        self.env(|mut env| {
            let tunnel_address_v4 = env.new_string(tunnel_address_v4.to_string()).unwrap();
            let tunnel_address_v6 = env.new_string(tunnel_address_v6.to_string()).unwrap();
            let dns_address = env
                .new_string(serde_json::to_string(&dns_address).unwrap())
                .unwrap();
            call_method(
                &mut env,
                &self.callback_handler,
                "onSetInterfaceConfig",
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)",
                &[
                    JValue::from(&tunnel_address_v4),
                    JValue::from(&tunnel_address_v6),
                    JValue::from(&dns_address),
                ],
            )
        })
    }

    fn on_tunnel_ready(&self) {
        self.env(|mut env| {
            call_method(&mut env, &self.callback_handler, "onTunnelReady", "()", &[])
        })
    }

    fn on_add_route(&self, route: String) {
        self.env(|mut env| {
            let route = env
                .new_string(serde_json::to_string(&route).unwrap())
                .unwrap();
            call_method(
                &mut env,
                &self.callback_handler,
                "onAddRoute",
                "(Ljava/lang/String;)",
                &[JValue::from(&route)],
            );
        })
    }

    fn on_remove_route(&self, route: String) {
        self.env(|mut env| {
            let route = env
                .new_string(serde_json::to_string(&route).unwrap())
                .unwrap();
            call_method(
                &mut env,
                &self.callback_handler,
                "onRemoveRoute",
                "(Ljava/lang/String;)",
                &[JValue::from(&route)],
            );
        })
    }

    fn on_update_resources(&self, resource_list: Vec<ResourceDescription>) {
        self.env(|mut env| {
            let resource_list = env
                .new_string(serde_json::to_string(&resource_list).unwrap())
                .unwrap();
            call_method(
                &mut env,
                &self.callback_handler,
                "onUpdateResources",
                "(Ljava/lang/String;)",
                &[JValue::from(&resource_list)],
            );
        })
    }

    fn on_disconnect(&self, error: Option<&Error>) {
        self.env(|mut env| {
            let error = env
                .new_string(serde_json::to_string(&error.map(ToString::to_string)).unwrap())
                .unwrap();
            call_method(
                &mut env,
                &self.callback_handler,
                "onDisconnect",
                "(Ljava/lang/String;)",
                &[JValue::from(&error)],
            );
        })
    }

    fn on_error(&self, error: &Error) {
        self.env(|mut env| {
            let error = env.new_string(error.to_string()).unwrap();
            call_method(
                &mut env,
                &self.callback_handler,
                "onError",
                "(Ljava/lang/String;)",
                &[JValue::from(&error)],
            );
        })
    }
}

/// # Safety
/// Pointers must be valid
#[allow(non_snake_case)]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_connlib_Session_connect(
    mut env: JNIEnv<'static>,
    _class: JClass,
    portal_url: JString,
    portal_token: JString,
    callback_handler: JObject<'static>,
) -> *const Session<CallbackHandler> {
    let portal_url = String::from(env.get_string(&portal_url).unwrap());
    let portal_token = env.get_string(&portal_token).unwrap().into();
    let callback_handler = CallbackHandler {
        vm: env.get_java_vm().unwrap(),
        callback_handler,
    };
    match Session::connect(portal_url.as_str(), portal_token, callback_handler.clone()) {
        Ok(session) => Box::into_raw(Box::new(session)),
        Err(err) => {
            callback_handler.on_error(&err);
            std::ptr::null()
        }
    }
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
