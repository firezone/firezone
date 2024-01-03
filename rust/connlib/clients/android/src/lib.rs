// The "system" ABI is only needed for Java FFI on Win32, not Android:
// https://github.com/jni-rs/jni-rs/pull/22
// However, this consideration has made it idiomatic for Java FFI in the Rust
// ecosystem, so it's used here for consistency.

use connlib_client_shared::{file_logger, Callbacks, Error, ResourceDescription, Session};
use ip_network::IpNetwork;
use jni::{
    objects::{GlobalRef, JByteArray, JClass, JObject, JObjectArray, JString, JValue, JValueGen},
    strings::JNIString,
    JNIEnv, JavaVM,
};
use secrecy::SecretString;
use std::{net::IpAddr, path::Path};
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    path::PathBuf,
};
use std::{sync::OnceLock, time::Duration};
use thiserror::Error;
use tracing_subscriber::prelude::*;
use tracing_subscriber::EnvFilter;

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

#[cfg(target_os = "android")]
fn android_layer<S>() -> impl tracing_subscriber::Layer<S>
where
    S: tracing::Subscriber + for<'span> tracing_subscriber::registry::LookupSpan<'span>,
{
    tracing_android::layer("connlib").unwrap()
}

#[cfg(not(target_os = "android"))]
fn android_layer<S>() -> impl tracing_subscriber::Layer<S>
where
    S: tracing::Subscriber,
{
    tracing_subscriber::layer::Identity::new()
}

fn init_logging(log_dir: &Path, log_filter: String) -> file_logger::Handle {
    // On Android, logging state is persisted indefinitely after the System.loadLibrary
    // call, which means that a disconnect and tunnel process restart will not
    // reinitialize the guard. This is a problem because the guard remains tied to
    // the original process, which means that log events will not be rewritten to the log
    // file after a disconnect and reconnect.
    //
    // So we use a static variable to track whether the guard has been initialized and avoid
    // re-initialized it if so.
    static LOGGING_HANDLE: OnceLock<file_logger::Handle> = OnceLock::new();
    if let Some(handle) = LOGGING_HANDLE.get() {
        return handle.clone();
    }

    let (file_layer, handle) = file_logger::layer(log_dir);

    LOGGING_HANDLE
        .set(handle.clone())
        .expect("Logging guard should never be initialized twice");

    let _ = tracing_subscriber::registry()
        .with(file_layer.with_filter(EnvFilter::new(log_filter.clone())))
        .with(android_layer().with_filter(EnvFilter::new(log_filter.clone())))
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
    ) -> Result<Option<RawFd>, Self::Error> {
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
            let name = "onSetInterfaceConfig";
            env.call_method(
                &self.callback_handler,
                name,
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)I",
                &[
                    JValue::from(&tunnel_address_v4),
                    JValue::from(&tunnel_address_v6),
                    JValue::from(&dns_address),
                ],
            )
            .and_then(|val| val.i())
            .map(Some)
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

    fn on_add_route(&self, route: IpNetwork) -> Result<Option<RawFd>, Self::Error> {
        self.env(|mut env| {
            let ip = env
                .new_string(route.network_address().to_string())
                .map_err(|source| CallbackError::NewStringFailed {
                    name: "route_ip",
                    source,
                })?;

            let name = "onAddRoute";
            env.call_method(
                &self.callback_handler,
                name,
                "(Ljava/lang/String;I)I",
                &[JValue::from(&ip), JValue::Int(route.netmask().into())],
            )
            .and_then(|val| val.i())
            .map(Some)
            .map_err(|source| CallbackError::CallMethodFailed { name, source })
        })
    }

    fn on_remove_route(&self, route: IpNetwork) -> Result<Option<RawFd>, Self::Error> {
        self.env(|mut env| {
            let ip = env
                .new_string(route.network_address().to_string())
                .map_err(|source| CallbackError::NewStringFailed {
                    name: "route_ip",
                    source,
                })?;

            let name = "onRemoveRoute";
            env.call_method(
                &self.callback_handler,
                name,
                "(Ljava/lang/String;I)I",
                &[JValue::from(&ip), JValue::Int(route.netmask().into())],
            )
            .and_then(|val| val.i())
            .map(Some)
            .map_err(|source| CallbackError::CallMethodFailed { name, source })
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

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.handle.roll_to_new_file().unwrap_or_else(|e| {
            tracing::debug!("Failed to roll over to new file: {e}");
            let _ = self.on_error(&Error::LogFileRollError(e));

            None
        })
    }

    fn get_system_default_resolvers(&self) -> Result<Option<Vec<IpAddr>>, Self::Error> {
        self.env(|mut env| {
            let name = "getSystemDefaultResolvers";
            let addrs = env
                .call_method(&self.callback_handler, name, "()[[B", &[])
                .and_then(JValueGen::l)
                .and_then(|arr| convert_byte_array_array(&mut env, arr.into()))
                .map_err(|source| CallbackError::CallMethodFailed { name, source })?;

            Ok(Some(addrs.iter().filter_map(|v| to_ip(v)).collect()))
        })
    }
}

fn to_ip(val: &[u8]) -> Option<IpAddr> {
    let addr: Option<[u8; 4]> = val.try_into().ok();
    if let Some(addr) = addr {
        return Some(addr.into());
    }

    let addr: [u8; 16] = val.try_into().ok()?;
    Some(addr.into())
}

fn convert_byte_array_array(
    env: &mut JNIEnv,
    array: JObjectArray,
) -> jni::errors::Result<Vec<Vec<u8>>> {
    let len = env.get_array_length(&array)?;
    let mut result = Vec::with_capacity(len as usize);
    for i in 0..len {
        let arr: JByteArray<'_> = env.get_object_array_element(&array, i)?.into();
        result.push(env.convert_byte_array(arr)?);
    }
    Ok(result)
}

fn throw(env: &mut JNIEnv, class: &str, msg: impl Into<JNIString>) {
    if let Err(err) = env.throw_new(class, msg) {
        // We can't panic, since unwinding across the FFI boundary is UB...
        tracing::error!(?err, "failed to throw Java exception");
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

macro_rules! string_from_jstring {
    ($env:expr, $j:ident) => {
        String::from(
            ($env)
                .get_string(&($j))
                .map_err(|source| ConnectError::StringInvalid {
                    name: stringify!($j),
                    source,
                })?,
        )
    };
}

// TODO: Refactor this when we refactor PhoenixChannel.
// See https://github.com/firezone/firezone/issues/2158
#[allow(clippy::too_many_arguments)]
fn connect(
    env: &mut JNIEnv,
    api_url: JString,
    token: JString,
    device_id: JString,
    device_name: JString,
    os_version: JString,
    log_dir: JString,
    log_filter: JString,
    callback_handler: GlobalRef,
) -> Result<Session<CallbackHandler>, ConnectError> {
    let api_url = string_from_jstring!(env, api_url);
    let secret = SecretString::from(string_from_jstring!(env, token));
    let device_id = string_from_jstring!(env, device_id);
    let device_name = string_from_jstring!(env, device_name);
    let os_version = string_from_jstring!(env, os_version);
    let log_dir = string_from_jstring!(env, log_dir);
    let log_filter = string_from_jstring!(env, log_filter);

    let handle = init_logging(&PathBuf::from(log_dir), log_filter);

    let callback_handler = CallbackHandler {
        vm: env.get_java_vm().map_err(ConnectError::GetJavaVmFailed)?,
        callback_handler,
        handle,
    };

    let session = Session::connect(
        api_url.as_str(),
        secret,
        device_id,
        Some(device_name),
        Some(os_version),
        callback_handler,
        Duration::from_secs(5 * 60),
    )?;

    Ok(session)
}

/// # Safety
/// Pointers must be valid
/// fd must be a valid file descriptor
#[allow(non_snake_case)]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_TunnelSession_connect(
    mut env: JNIEnv,
    _class: JClass,
    api_url: JString,
    token: JString,
    device_id: JString,
    device_name: JString,
    os_version: JString,
    log_dir: JString,
    log_filter: JString,
    callback_handler: JObject,
) -> *const Session<CallbackHandler> {
    let Ok(callback_handler) = env.new_global_ref(callback_handler) else {
        return std::ptr::null();
    };

    let connect = catch_and_throw(&mut env, |env| {
        connect(
            env,
            api_url,
            token,
            device_id,
            device_name,
            os_version,
            log_dir,
            log_filter,
            callback_handler,
        )
    });

    let session = match connect {
        Some(Ok(session)) => session,
        Some(Err(err)) => {
            throw(&mut env, "java/lang/Exception", err.to_string());
            return std::ptr::null();
        }
        None => return std::ptr::null(),
    };

    Box::into_raw(Box::new(session))
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
