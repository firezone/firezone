// The "system" ABI is only needed for Java FFI on Win32, not Android:
// https://github.com/jni-rs/jni-rs/pull/22
// However, this consideration has made it idiomatic for Java FFI in the Rust
// ecosystem, so it's used here for consistency.

use crate::tun::Tun;
use backoff::ExponentialBackoffBuilder;
use connlib_client_shared::{Callbacks, DisconnectError, Session, V4RouteList, V6RouteList};
use connlib_model::{ResourceId, ResourceView};
use firezone_logging::std_dyn_err;
use firezone_telemetry::{Telemetry, ANDROID_DSN};
use ip_network::{Ipv4Network, Ipv6Network};
use jni::{
    objects::{GlobalRef, JClass, JObject, JString, JValue},
    strings::JNIString,
    sys::jlong,
    JNIEnv, JavaVM,
};
use phoenix_channel::get_user_agent;
use phoenix_channel::PhoenixChannel;
use phoenix_channel::{LoginUrl, LoginUrlError};
use secrecy::{Secret, SecretString};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{collections::BTreeSet, io, net::IpAddr, os::fd::AsRawFd, path::Path, sync::Arc};
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

pub struct CallbackHandler {
    vm: JavaVM,
    callback_handler: GlobalRef,
    handle: firezone_logging::file::Handle,
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

fn init_logging(log_dir: &Path, log_filter: String) -> firezone_logging::file::Handle {
    // On Android, logging state is persisted indefinitely after the System.loadLibrary
    // call, which means that a disconnect and tunnel process restart will not
    // reinitialize the guard. This is a problem because the guard remains tied to
    // the original process, which means that log events will not be rewritten to the log
    // file after a disconnect and reconnect.
    //
    // So we use a static variable to track whether the guard has been initialized and avoid
    // re-initialized it if so.
    static LOGGING_HANDLE: OnceLock<firezone_logging::file::Handle> = OnceLock::new();
    if let Some(handle) = LOGGING_HANDLE.get() {
        return handle.clone();
    }

    let (file_layer, handle) = firezone_logging::file::layer(log_dir);

    LOGGING_HANDLE
        .set(handle.clone())
        .expect("Logging guard should never be initialized twice");

    let _ = tracing_subscriber::registry()
        .with(file_layer)
        .with(
            tracing_subscriber::fmt::layer()
                .event_format(
                    firezone_logging::Format::new()
                        .without_ansi()
                        .without_timestamp()
                        .without_level(),
                )
                .with_writer(make_writer::MakeWriter::new("connlib")),
        )
        .with(firezone_logging::filter(&log_filter))
        .try_init();

    handle
}

impl Callbacks for CallbackHandler {
    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_addresses: Vec<IpAddr>,
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
            let name = "onSetInterfaceConfig";
            env.call_method(
                &self.callback_handler,
                name,
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
                &[
                    JValue::from(&tunnel_address_v4),
                    JValue::from(&tunnel_address_v6),
                    JValue::from(&dns_addresses),
                ],
            )
            .map_err(|source| CallbackError::CallMethodFailed { name, source })?;

            Ok(())
        })
        .expect("onSetInterfaceConfig callback failed");
    }

    fn on_update_routes(&self, route_list_4: Vec<Ipv4Network>, route_list_6: Vec<Ipv6Network>) {
        self.env(|mut env| {
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

            let name = "onUpdateRoutes";
            env.call_method(
                &self.callback_handler,
                name,
                "(Ljava/lang/String;Ljava/lang/String;)V",
                &[JValue::from(&route_list_4), JValue::from(&route_list_6)],
            )
            .map_err(|source| CallbackError::CallMethodFailed { name, source })?;

            Ok(())
        })
        .expect("onUpdateRoutes callback failed");
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

    fn on_disconnect(&self, error: &DisconnectError) {
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
        tracing::error!(error = std_dyn_err(&err), "failed to throw Java exception");
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
    ConnectFailed(#[from] DisconnectError),
    #[error(transparent)]
    InvalidLoginUrl(#[from] LoginUrlError<url::ParseError>),
    #[error("Unable to create tokio runtime: {0}")]
    UnableToCreateRuntime(#[from] io::Error),
    #[error(transparent)]
    CallbackError(#[from] CallbackError),
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
) -> Result<SessionWrapper, ConnectError> {
    let api_url = string_from_jstring!(env, api_url);
    let secret = SecretString::from(string_from_jstring!(env, token));
    let device_id = string_from_jstring!(env, device_id);
    let device_name = string_from_jstring!(env, device_name);
    let os_version = string_from_jstring!(env, os_version);
    let log_dir = string_from_jstring!(env, log_dir);
    let log_filter = string_from_jstring!(env, log_filter);
    let device_info = string_from_jstring!(env, device_info);
    let device_info = serde_json::from_str(&device_info).unwrap();

    let telemetry = Telemetry::default();
    telemetry.start(&api_url, env!("CARGO_PKG_VERSION"), ANDROID_DSN);

    let handle = init_logging(&PathBuf::from(log_dir), log_filter);
    install_rustls_crypto_provider();

    let callbacks = CallbackHandler {
        vm: env.get_java_vm().map_err(ConnectError::GetJavaVmFailed)?,
        callback_handler,
        handle,
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
        ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(Some(MAX_PARTITION_TIME))
            .build(),
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
#[no_mangle]
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
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_disconnect(
    mut env: JNIEnv,
    _: JClass,
    session_ptr: jlong,
) {
    let session = session_ptr as *mut SessionWrapper;
    catch_and_throw(&mut env, |_| {
        let session = Box::from_raw(session);

        session.runtime.block_on(session.telemetry.stop());
        session.inner.disconnect();
    });
}

///
///
/// # Safety
/// session_ptr should have been obtained from `connect` function, and shouldn't be dropped with disconnect
/// at any point before or during operation of this function.
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_setDisabledResources(
    mut env: JNIEnv,
    _: JClass,
    session_ptr: jlong,
    disabled_resources: JString,
) {
    let disabled_resources = String::from(
        env.get_string(&disabled_resources)
            .map_err(|source| ConnectError::StringInvalid {
                name: "disabled_resources",
                source,
            })
            .expect("Invalid string returned from android client"),
    );
    let disabled_resources: BTreeSet<ResourceId> =
        serde_json::from_str(&disabled_resources).unwrap();
    tracing::debug!("disabled resource: {disabled_resources:?}");
    let session = &*(session_ptr as *const SessionWrapper);
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
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_setDns(
    mut env: JNIEnv,
    _: JClass,
    session_ptr: jlong,
    dns_list: JString,
) {
    let dns = String::from(
        env.get_string(&dns_list)
            .map_err(|source| ConnectError::StringInvalid {
                name: "dns_list",
                source,
            })
            .expect("Invalid string returned from android client"),
    );
    let dns: Vec<IpAddr> = serde_json::from_str(&dns).unwrap();
    let session = &*(session_ptr as *const SessionWrapper);
    session.inner.set_dns(dns);
}

/// # Safety
/// session_ptr should have been obtained from `connect` function, and shouldn't be dropped with disconnect
/// at any point before or during operation of this function.
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_reset(
    _: JNIEnv,
    _: JClass,
    session_ptr: jlong,
) {
    let session = &*(session_ptr as *const SessionWrapper);
    session.inner.reset();
}

/// # Safety
/// session_ptr should have been obtained from `connect` function, and shouldn't be dropped with disconnect
/// at any point before or during operation of this function.
#[no_mangle]
pub unsafe extern "system" fn Java_dev_firezone_android_tunnel_ConnlibSession_setTun(
    mut env: JNIEnv,
    _: JClass,
    session_ptr: jlong,
    fd: RawFd,
) {
    let session = &*(session_ptr as *const SessionWrapper);

    // Enter tokio RT context to construct `Tun`.
    let _enter = session.runtime.enter();
    let tun = match Tun::from_fd(fd) {
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
