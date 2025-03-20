// The "system" ABI is only needed for Java FFI on Win32, not Android:
// https://github.com/jni-rs/jni-rs/pull/22
// However, this consideration has made it idiomatic for Java FFI in the Rust
// ecosystem, so it's used here for consistency.

#![cfg(unix)]

use crate::tun::Tun;
use anyhow::{Context as _, Result};
use backoff::ExponentialBackoffBuilder;
use connlib_client_shared::{Callbacks, DisconnectError, Session, V4RouteList, V6RouteList};
use connlib_model::ResourceView;
use dns_types::DomainName;
use firezone_logging::{err_with_src, sentry_layer};
use firezone_telemetry::{ANDROID_DSN, Telemetry};
use ip_network::{Ipv4Network, Ipv6Network};
use jni::{
    JNIEnv, JavaVM,
    objects::{GlobalRef, JClass, JObject, JString, JValue},
    strings::JNIString,
    sys::jlong,
};
use phoenix_channel::LoginUrl;
use phoenix_channel::PhoenixChannel;
use phoenix_channel::get_user_agent;
use secrecy::{Secret, SecretString};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{io, net::IpAddr, os::fd::AsRawFd, path::Path, sync::Arc};
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::fd::RawFd,
    path::PathBuf,
};
use std::{sync::OnceLock, time::Duration};
use thiserror::Error;
use tokio::runtime::Runtime;
use tracing_subscriber::prelude::*;

mod make_writer;
mod tun;

/// The Android client doesn't use platform APIs to detect network connectivity changes,
/// so we rely on connlib to do so. We have valid use cases for headless Android clients
/// (IoT devices, point-of-sale devices, etc), so try to reconnect for 30 days.
const MAX_PARTITION_TIME: Duration = Duration::from_secs(60 * 60 * 24 * 30);

/// The Sentry release.
///
/// This module is only responsible for the connlib part of the Android app.
/// Bugs within the Android app itself may use the same DSN but a different component as part of the version string.
const RELEASE: &str = concat!("connlib-android@", env!("CARGO_PKG_VERSION"));

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
    #[error(transparent)]
    Io(#[from] io::Error),
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

    fn protect(&self, socket: RawFd) -> io::Result<()> {
        self.env(|mut env| {
            call_method(
                &mut env,
                &self.callback_handler,
                "protectFileDescriptor",
                "(I)V",
                &[JValue::Int(socket)],
            )
        })
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))
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

fn init_logging(log_dir: &Path, log_filter: String) -> Result<()> {
    static LOGGER_STATE: OnceLock<(
        firezone_logging::file::Handle,
        firezone_logging::FilterReloadHandle,
    )> = OnceLock::new();
    if let Some((_, reload_handle)) = LOGGER_STATE.get() {
        reload_handle
            .reload(&log_filter)
            .context("Failed to apply new log-filter")?;
        return Ok(());
    }

    let (log_filter, reload_handle) = firezone_logging::try_filter(&log_filter)?;
    let (file_layer, handle) = firezone_logging::file::layer(log_dir, "connlib");

    let subscriber = tracing_subscriber::registry()
        .with(log_filter)
        .with(file_layer)
        .with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .event_format(
                    firezone_logging::Format::new()
                        .without_timestamp()
                        .without_level(),
                )
                .with_writer(make_writer::MakeWriter::new("connlib")),
        )
        .with(sentry_layer());

    firezone_logging::init(subscriber)?;

    LOGGER_STATE
        .set((handle, reload_handle))
        .expect("Logging guard should never be initialized twice");

    Ok(())
}

impl Callbacks for CallbackHandler {
    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_addresses: Vec<IpAddr>,
        search_domain: Option<DomainName>,
        route_list_4: Vec<Ipv4Network>,
        route_list_6: Vec<Ipv6Network>,
    ) {
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
            let dns_addresses = env
                .new_string(serde_json::to_string(&dns_addresses)?)
                .map_err(|source| CallbackError::NewStringFailed {
                    name: "dns_addresses",
                    source,
                })?;
            let search_domain = search_domain
                .map(|domain| {
                    env.new_string(domain.to_string())
                        .map_err(|source| CallbackError::NewStringFailed {
                            name: "search_domain",
                            source,
                        })
                })
                .transpose()?
                .unwrap_or_default();
            let route_list_4 = env
                .new_string(serde_json::to_string(&V4RouteList::new(route_list_4))?)
                .map_err(|source| CallbackError::NewStringFailed {
                    name: "route_list_4",
                    source,
                })?;
            let route_list_6 = env
                .new_string(serde_json::to_string(&V6RouteList::new(route_list_6))?)
                .map_err(|source| CallbackError::NewStringFailed {
                    name: "route_list_6",
                    source,
                })?;

            let name = "onSetInterfaceConfig";
            env.call_method(
                &self.callback_handler,
                name,
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
                &[
                    JValue::from(&tunnel_address_v4),
                    JValue::from(&tunnel_address_v6),
                    JValue::from(&dns_addresses),
                    JValue::from(&search_domain),
                    JValue::from(&route_list_4),
                    JValue::from(&route_list_6),
                ],
            )
            .map_err(|source| CallbackError::CallMethodFailed { name, source })?;

            Ok(())
        })
        .expect("onSetInterfaceConfig callback failed");
    }

    fn on_update_resources(&self, resource_list: Vec<ResourceView>) {
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
        .expect("onUpdateResources callback failed")
    }

    fn on_disconnect(&self, error: DisconnectError) {
        self.env(|mut env| {
            let error = env
                .new_string(serde_json::to_string(&error.to_string())?)
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
        .expect("onDisconnect callback failed")
    }
}

fn throw(env: &mut JNIEnv, class: &str, msg: impl Into<JNIString>) {
    if let Err(err) = env.throw_new(class, msg) {
        // We can't panic, since unwinding across the FFI boundary is UB...
        tracing::error!("failed to throw Java exception: {}", err_with_src(&err));
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

macro_rules! string_from_jstring {
    ($env:expr, $j:ident) => {
        String::from(
            ($env)
                .get_string(&($j))
                .with_context(|| format!("Failed to get string {} from JNIEnv", stringify!($j)))?,
        )
    };
}

// TODO: Refactor this when we refactor PhoenixChannel.
// See https://github.com/firezone/firezone/issues/2158
#[expect(clippy::too_many_arguments)]
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
    device_info: JString,
) -> Result<SessionWrapper> {
    let api_url = string_from_jstring!(env, api_url);
    let secret = SecretString::from(string_from_jstring!(env, token));
    let device_id = string_from_jstring!(env, device_id);
    let device_name = string_from_jstring!(env, device_name);
    let os_version = string_from_jstring!(env, os_version);
    let log_dir = string_from_jstring!(env, log_dir);
    let log_filter = string_from_jstring!(env, log_filter);

    let device_info = string_from_jstring!(env, device_info);
    let device_info =
        serde_json::from_str(&device_info).context("Failed to deserialize `DeviceInfo`")?;

    let mut telemetry = Telemetry::default();
    telemetry.start(&api_url, RELEASE, ANDROID_DSN);
    Telemetry::set_firezone_id(device_id.clone());

    init_logging(&PathBuf::from(log_dir), log_filter)?;
    install_rustls_crypto_provider();

    let callbacks = CallbackHandler {
        vm: env.get_java_vm()?,
        callback_handler,
    };

    let url = LoginUrl::client(
        api_url.as_str(),
        &secret,
        device_id,
        Some(device_name),
        device_info,
    )?;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("connlib")
        .enable_all()
        .build()?;
    let _guard = runtime.enter(); // Constructing `PhoenixChannel` requires a runtime context.

    let tcp_socket_factory = Arc::new(protected_tcp_socket_factory(callbacks.clone()));

    let portal = PhoenixChannel::disconnected(
        Secret::new(url),
        get_user_agent(Some(os_version), env!("CARGO_PKG_VERSION")),
        "client",
        (),
        || {
            ExponentialBackoffBuilder::default()
                .with_max_elapsed_time(Some(MAX_PARTITION_TIME))
                .build()
        },
        tcp_socket_factory,
    )?;
    let session = Session::connect(
        Arc::new(protected_tcp_socket_factory(callbacks.clone())),
        Arc::new(protected_udp_socket_factory(callbacks.clone())),
        callbacks,
        portal,
        runtime.handle().clone(),
    );

    Ok(SessionWrapper {
        inner: session,
        runtime,
        telemetry,
    })
}

/// # Safety
/// Pointers must be valid
/// fd must be a valid file descriptor
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_connect(
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
    device_info: JString,
) -> *const SessionWrapper {
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
            device_info,
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

    // Note: this pointer will probably be casted into a jlong after it is received by android.
    // jlong is 64bits so the worst case scenario it will be padded, in that case, when casting it back to a pointer we expect `as` to select only the relevant bytes
    Box::into_raw(Box::new(session))
}

pub struct SessionWrapper {
    inner: Session,

    runtime: Runtime,
    telemetry: Telemetry,
}

/// # Safety
/// session_ptr should have been obtained from `connect` function
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_disconnect(
    mut env: JNIEnv,
    _: JClass,
    session_ptr: jlong,
) {
    // Creating an owned `Box` from this will properly drop this at the end of the scope.
    let mut session = unsafe { Box::from_raw(session_ptr as *mut SessionWrapper) };

    catch_and_throw(&mut env, |_| {
        session.runtime.block_on(session.telemetry.stop());
    });
}

/// # Safety
/// session_ptr should have been obtained from `connect` function, and shouldn't be dropped with disconnect
/// at any point before or during operation of this function.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_setDisabledResources(
    mut env: JNIEnv,
    _: JClass,
    session_ptr: jlong,
    disabled_resources: JString,
) {
    let session = unsafe { &*(session_ptr as *const SessionWrapper) };

    let disabled_resources = String::from(
        env.get_string(&disabled_resources)
            .expect("Invalid string returned from android client"),
    );
    let disabled_resources = serde_json::from_str(&disabled_resources)
        .expect("Failed to deserialize disabled resource IDs");

    tracing::debug!("disabled resource: {disabled_resources:?}");
    session.inner.set_disabled_resources(disabled_resources);
}

/// Set system DNS resolvers
///
/// `dns_list` must not have any IPv6 scopes
/// <https://github.com/firezone/firezone/issues/4350>
/// <https://github.com/firezone/firezone/issues/5781>
///
/// # Safety
/// session_ptr should have been obtained from `connect` function, and shouldn't be dropped with disconnect
/// at any point before or during operation of this function.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_setDns(
    mut env: JNIEnv,
    _: JClass,
    session_ptr: jlong,
    dns_list: JString,
) {
    let session = unsafe { &*(session_ptr as *const SessionWrapper) };

    let dns = String::from(
        env.get_string(&dns_list)
            .expect("Invalid string returned from android client"),
    );
    let dns = serde_json::from_str::<Vec<IpAddr>>(&dns).expect("Failed to deserialize DNS IPs");

    session.inner.set_dns(dns);
}

/// # Safety
/// session_ptr should have been obtained from `connect` function, and shouldn't be dropped with disconnect
/// at any point before or during operation of this function.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_reset(
    _: JNIEnv,
    _: JClass,
    session_ptr: jlong,
) {
    let session = unsafe { &*(session_ptr as *const SessionWrapper) };

    session.inner.reset();
}

/// # Safety
/// session_ptr should have been obtained from `connect` function, and shouldn't be dropped with disconnect
/// at any point before or during operation of this function.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_setTun(
    mut env: JNIEnv,
    _: JClass,
    session_ptr: jlong,
    fd: RawFd,
) {
    let session = unsafe { &*(session_ptr as *const SessionWrapper) };

    // Enter tokio RT context to construct `Tun`.
    let _enter = session.runtime.enter();
    let tun_result = unsafe { Tun::from_fd(fd) };

    let tun = match tun_result {
        Ok(t) => t,
        Err(e) => {
            throw(&mut env, "java/lang/Exception", e.to_string());
            return;
        }
    };

    session.inner.set_tun(Box::new(tun));
}

fn protected_tcp_socket_factory(callbacks: CallbackHandler) -> impl SocketFactory<TcpSocket> {
    move |addr| {
        let socket = socket_factory::tcp(addr)?;
        callbacks.protect(socket.as_raw_fd())?;
        Ok(socket)
    }
}

fn protected_udp_socket_factory(callbacks: CallbackHandler) -> impl SocketFactory<UdpSocket> {
    move |addr| {
        let socket = socket_factory::udp(addr)?;
        callbacks.protect(socket.as_raw_fd())?;
        Ok(socket)
    }
}

/// Installs the `ring` crypto provider for rustls.
fn install_rustls_crypto_provider() {
    let existing = rustls::crypto::ring::default_provider().install_default();

    if existing.is_err() {
        // On Android, connlib gets loaded as shared library by the JVM and may remain loaded even if we disconnect the tunnel.
        tracing::debug!("Skipping install of crypto provider because we already have one.");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_jstring_is_null() {
        assert!(JString::default().is_null())
    }
}
