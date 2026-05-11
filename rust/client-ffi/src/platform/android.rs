use std::time::Duration;

use jni::errors::{Error as JNIError, ThrowRuntimeExAndDefault};
use jni::objects::{JClass, JObject};
use jni::strings::JNIString;
use jni::{EnvUnowned, jni_str};
use telemetry::Dsn;

mod make_writer;
mod tun;

// mark:next-android-version
pub const RELEASE: &str = "connlib-android@1.5.11";
// mark:next-android-version
pub const VERSION: &str = "1.5.11";
pub const COMPONENT: &str = "android-client";

/// We have valid use cases for headless Android clients
/// (IoT devices, point-of-sale devices, etc), so try to reconnect for 30 days.
pub const MAX_PARTITION_TIME: Duration = Duration::from_secs(60 * 60 * 24 * 30);

pub const DSN: Dsn = telemetry::ANDROID_DSN;

pub(crate) use make_writer::MakeWriter;
pub(crate) use tun::Tun;

/// JNI entrypoint that wires `rustls-platform-verifier` to the Android runtime.
///
/// `reqwest` (and through it Sentry) defers TLS certificate verification to
/// `rustls-platform-verifier`, which on Android needs a `JavaVM` + `Context`
/// to call into the JVM's `X509TrustManagerFactory`. Other platforms self-init
/// from native APIs; Android must be told. Without this, the first TLS handshake
/// panics with `Expect rustls-platform-verifier to be initialized`.
///
/// Called once from `FirezoneApp.onCreate`, after `System.loadLibrary("connlib")`.
#[unsafe(no_mangle)]
extern "system" fn Java_dev_firezone_android_core_FirezoneApp_initRustlsPlatformVerifier<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _class: JClass<'local>,
    context: JObject<'local>,
) {
    unowned_env
        .with_env(|env| -> Result<(), JNIError> {
            if let Err(err) = rustls_platform_verifier::android::init_with_env(env, context) {
                let _ = env.throw_new(
                    jni_str!("java/lang/IllegalStateException"),
                    JNIString::from(format!(
                        "rustls-platform-verifier init failed; later TLS handshakes may fail: {err}"
                    )),
                );
            }
            Ok(())
        })
        .resolve::<ThrowRuntimeExAndDefault>();
}
