// The "system" ABI is only needed for Java FFI on Win32, not Android:
// https://github.com/jni-rs/jni-rs/pull/22
// However, this consideration has made it idiomatic for Java FFI in the Rust
// ecosystem, so it's used here for consistency.

use firezone_client_connlib::{file_logger, Callbacks, Error, ResourceDescription, Session};
use ip_network::IpNetwork;
use jni::{
    objects::{GlobalRef, JClass, JObject, JString, JValue},
    strings::JNIString,
    JNIEnv, JavaVM,
};
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    path::PathBuf,
};
use thiserror::Error;
use tracing::log::LevelFilter;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::prelude::*;

pub struct CallbackHandler {
    vm: JavaVM,
    callback_handler: GlobalRef,
}

impl Clone for CallbackHandler {
    fn clone(&self) -> Self {
        // This is essentially a `memcpy` to bypass redundant checks from
        // doing `as_raw` -> `from_raw`/etc; both of these fields are just
        // dumb pointers but the wrappers don't implement `Clone`.
        //
        // SAFETY: `self` is guaranteed to be valid and `Self` is POD.
        Self {
            vm: unsafe { std::ptr::read(&self.vm) },
            callback_handler: self.callback_handler.clone(),
        }
    }
}

#[derive(Debug, Error)]
pub enum CallbackError {
    #[error("Failed to attach current thread: {0}")]
    AttachCurrentThreadFailed(#[source] jni::errors::Error),
    #[error("Failed to serialize JSON: {0}")]
    SerializeFailed(#[from] serde_json::Error),
    #[error("Failed to create string `{name}`: {source}")]
    NewStringFailed {
        name: &'static str,
        source: jni::errors::Error,
    },
    #[error("Failed to call method `{name}`: {source}")]
    CallMethodFailed {
        name: &'static str,
        source: jni::errors::Error,
    },
}

impl CallbackHandler {
    fn env<T>(
        &self,
        f: impl FnOnce(JNIEnv) -> Result<T, CallbackError>,
    ) -> Result<T, CallbackError> {
        self.vm
            .attach_current_thread_as_daemon()
            .map_err(CallbackError::AttachCurrentThreadFailed)
            .and_then(f)
    }
}

fn call_method(
    env: &mut JNIEnv,
    this: &JObject,
    name: &'static str,
    sig: &str,
    args: &[JValue],
) -> Result<(), CallbackError> {
    env.call_method(this, name, sig, args)
        .map(|val| log::trace!("`{name}` returned `{val:?}`"))
        .map_err(|source| CallbackError::CallMethodFailed { name, source })
}

fn init_logging(log_dir: PathBuf) -> WorkerGuard {
    #[cfg(debug_assertions)]
    let log_level = LevelFilter::Debug;

    #[cfg(not(debug_assertions))]
    let log_level = LevelFilter::Info;

    // Initializes integration with Logcat for Android
    // This can be called many times, but will only initialize logging once
    android_logger::init_once(android_logger::Config::default().with_max_level(log_level));

    let (file_layer, guard) = file_logger::layer(log_dir);

    // Calling init twice causes a panic; instead use try_init which will fail
    // gracefully if this is called more than once.
    let _ = tracing_subscriber::registry().with(file_layer).try_init();

    guard
}

impl Callbacks for CallbackHandler {
    type Error = CallbackError;

    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_address: Ipv4Addr,
        dns_fallback_strategy: String,
    ) -> Result<RawFd, Self::Error> {
        self.env(|mut env| {
            let tunnel_address_v4 =
                env.new_string(tunnel_address_v4.to_string())
                    .map_err(|source| CallbackError::NewStringFailed {
                        name: "tunnel_address_v4",
                        source,
                    })?;
            let tunnel_address_v6 =
                env.new_string(tunnel_address_v6.to_string())
                    .map_err(|source| CallbackError::NewStringFailed {
                        name: "tunnel_address_v6",
                        source,
                    })?;
            let dns_address = env.new_string(dns_address.to_string()).map_err(|source| {
                CallbackError::NewStringFailed {
                    name: "dns_address",
                    source,
                }
            })?;
            let dns_fallback_strategy =
                env.new_string(dns_fallback_strategy).map_err(|source| {
                    CallbackError::NewStringFailed {
                        name: "dns_fallback_strategy",
                        source,
                    }
                })?;

            let name = "onSetInterfaceConfig";
            env.call_method(
                &self.callback_handler,
                name,
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)I",
                &[
                    JValue::from(&tunnel_address_v4),
                    JValue::from(&tunnel_address_v6),
                    JValue::from(&dns_address),
                    JValue::from(&dns_fallback_strategy),
                ],
            )
            .and_then(|val| val.i())
            .map_err(|source| CallbackError::CallMethodFailed { name, source })
        })
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        self.env(|mut env| {
            call_method(
                &mut env,
                &self.callback_handler,
                "onTunnelReady",
                "()Z",
                &[],
            )
        })
    }

    fn on_add_route(&self, route: IpNetwork) -> Result<(), Self::Error> {
        self.env(|mut env| {
            let route = env.new_string(route.to_string()).map_err(|source| {
                CallbackError::NewStringFailed {
                    name: "route",
                    source,
                }
            })?;
            call_method(
                &mut env,
                &self.callback_handler,
                "onAddRoute",
                "(Ljava/lang/String;)V",
                &[JValue::from(&route)],
            )
        })
    }

    fn on_remove_route(&self, route: IpNetwork) -> Result<(), Self::Error> {
        self.env(|mut env| {
            let route = env.new_string(route.to_string()).map_err(|source| {
                CallbackError::NewStringFailed {
                    name: "route",
                    source,
                }
            })?;
            call_method(
                &mut env,
                &self.callback_handler,
                "onRemoveRoute",
                "(Ljava/lang/String;)V",
                &[JValue::from(&route)],
            )
        })
    }

    fn on_update_resources(
        &self,
        resource_list: Vec<ResourceDescription>,
    ) -> Result<(), Self::Error> {
        self.env(|mut env| {
            let resource_list = env
                .new_string(serde_json::to_string(&resource_list)?)
                .map_err(|source| CallbackError::NewStringFailed {
                    name: "resource_list",
                    source,
                })?;
            call_method(
                &mut env,
                &self.callback_handler,
                "onUpdateResources",
                "(Ljava/lang/String;)V",
                &[JValue::from(&resource_list)],
            )
        })
    }

    fn on_disconnect(&self, error: Option<&Error>) -> Result<(), Self::Error> {
        self.env(|mut env| {
            let error = env
                .new_string(serde_json::to_string(&error.map(ToString::to_string))?)
                .map_err(|source| CallbackError::NewStringFailed {
                    name: "error",
                    source,
                })?;
            call_method(
                &mut env,
                &self.callback_handler,
                "onDisconnect",
                "(Ljava/lang/String;)Z",
                &[JValue::from(&error)],
            )
        })
    }

    fn on_error(&self, error: &Error) -> Result<(), Self::Error> {
        self.env(|mut env| {
            let error = env.new_string(error.to_string()).map_err(|source| {
                CallbackError::NewStringFailed {
                    name: "error",
                    source,
                }
            })?;
            call_method(
                &mut env,
                &self.callback_handler,
                "onError",
                "(Ljava/lang/String;)Z",
                &[JValue::from(&error)],
            )
        })
    }
}

fn throw(env: &mut JNIEnv, class: &str, msg: impl Into<JNIString>) {
    if let Err(err) = env.throw_new(class, msg) {
        // We can't panic, since unwinding across the FFI boundary is UB...
        tracing::error!("failed to throw Java exception: {err}");
    }
}

fn catch_and_throw<F: FnOnce(&mut JNIEnv) -> R, R>(env: &mut JNIEnv, f: F) -> Option<R> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(env)))
        .map_err(|info| {
            tracing::error!("catching Rust panic");
            throw(
                env,
                "java/lang/Exception",
                match info.downcast_ref::<&str>() {
                    Some(msg) => format!("Rust panicked: {msg}"),
                    None => "Rust panicked with no message".to_owned(),
                },
            );
        })
        .ok()
}

#[derive(Debug, Error)]
enum ConnectError {
    #[error("Failed to access {name:?}: {source}")]
    StringInvalid {
        name: &'static str,
        source: jni::errors::Error,
    },
    #[error("Failed to get Java VM: {0}")]
    GetJavaVmFailed(#[source] jni::errors::Error),
    #[error(transparent)]
    ConnectFailed(#[from] Error),
}

fn connect(
    env: &mut JNIEnv,
    portal_url: JString,
    portal_token: JString,
    device_id: JString,
    log_dir: JString,
    callback_handler: GlobalRef,
) -> Result<Session<CallbackHandler>, ConnectError> {
    let portal_url = String::from(env.get_string(&portal_url).map_err(|source| {
        ConnectError::StringInvalid {
            name: "portal_url",
            source,
        }
    })?);
    let portal_token = String::from(env.get_string(&portal_token).map_err(|source| {
        ConnectError::StringInvalid {
            name: "portal_token",
            source,
        }
    })?);
    let device_id =
        String::from(
            env.get_string(&device_id)
                .map_err(|source| ConnectError::StringInvalid {
                    name: "device_id",
                    source,
                })?,
        );
    let log_dir =
        String::from(
            env.get_string(&log_dir)
                .map_err(|source| ConnectError::StringInvalid {
                    name: "log_dir",
                    source,
                })?,
        );
    let callback_handler = CallbackHandler {
        vm: env.get_java_vm().map_err(ConnectError::GetJavaVmFailed)?,
        callback_handler,
    };

    Session::connect(
        portal_url.as_str(),
        portal_token,
        device_id,
        Some(init_logging(log_dir.into())),
        callback_handler,
    )
    .map_err(Into::into)
}

/// # Safety
/// Pointers must be valid
/// fd must be a valid file descriptor
#[allow(non_snake_case)]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_TunnelSession_connect(
    mut env: JNIEnv,
    _class: JClass,
    portal_url: JString,
    portal_token: JString,
    device_id: JString,
    log_dir: JString,
    callback_handler: JObject,
) -> *const Session<CallbackHandler> {
    let Ok(callback_handler) = env.new_global_ref(callback_handler) else {
        return std::ptr::null();
    };

    if let Some(result) = catch_and_throw(&mut env, |env| {
        connect(
            env,
            portal_url,
            portal_token,
            device_id,
            log_dir,
            callback_handler,
        )
    }) {
        match result {
            Ok(session) => return Box::into_raw(Box::new(session)),
            Err(err) => throw(&mut env, "java/lang/Exception", err.to_string()),
        }
    }
    std::ptr::null()
}

/// # Safety
/// Pointers must be valid
#[allow(non_snake_case)]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_TunnelSession_disconnect(
    mut env: JNIEnv,
    _: JClass,
    session: *mut Session<CallbackHandler>,
) {
    tracing::debug!("disconnecting");

    let mut session = Box::from_raw(session);
    tracing::debug!("{}", session.callbacks.0.callback_handler.is_null());

    catch_and_throw(&mut env, |_| {
        session.disconnect(None);
    });

    tracing::debug!("disconnected");
}
