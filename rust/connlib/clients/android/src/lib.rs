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
use std::path::Path;
use std::sync::OnceLock;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    path::PathBuf,
};
use thiserror::Error;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::prelude::*;
use url::Url;

pub struct CallbackHandler {
    vm: JavaVM,
    callback_handler: GlobalRef,
    handle: file_logger::Handle,
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
            handle: self.handle.clone(),
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

fn init_logging(log_dir: &Path) -> file_logger::Handle {
    static LOGGING_GUARD: OnceLock<(WorkerGuard, file_logger::Handle)> = OnceLock::new();
    // On Android, logging state is persisted indefinitely after the System.loadLibrary
    // call, which means that a disconnect and tunnel process restart will not
    // reinitialize the guard. This is a problem because the guard remains tied to
    // the original process, which means that log events will not be rewritten to the log
    // file after a disconnect and reconnect.
    //
    // So we use a static variable to track whether the guard has been initialized and avoid
    // re-initialized it if so.
    if let Some((_, handle)) = LOGGING_GUARD.get() {
        return handle.clone();
    }

    let (file_layer, guard, handle) = file_logger::layer(log_dir);

    LOGGING_GUARD
        .set((guard, handle.clone()))
        .expect("Logging guard should never be initialized twice");

    let _ = tracing_subscriber::registry()
        .with(file_layer)
        .with(tracing_android::layer("connlib").unwrap())
        .try_init();

    handle
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

    fn upload_logs(&self, _: Url) {
        let old_file = match self.handle.roll_to_new_file() {
            Ok(Some(old_file)) => old_file,
            Ok(None) => {
                tracing::debug!("No log file yet, nothing to upload");
                return;
            }
            Err(e) => {
                tracing::debug!("Failed to roll over to new file: {e}");
                return;
            }
        };

        tracing::debug!("Uploading log-file {}", old_file.display());
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
    let log_dir = PathBuf::from(String::from(env.get_string(&log_dir).map_err(
        |source| ConnectError::StringInvalid {
            name: "log_dir",
            source,
        },
    )?));
    let handle = init_logging(&log_dir);

    let callback_handler = CallbackHandler {
        vm: env.get_java_vm().map_err(ConnectError::GetJavaVmFailed)?,
        callback_handler,
        handle,
    };

    Session::connect(
        portal_url.as_str(),
        portal_token,
        device_id,
        None,
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
    catch_and_throw(&mut env, |_| {
        Box::from_raw(session).disconnect(None);
    });
}
