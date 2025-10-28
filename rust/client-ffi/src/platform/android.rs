use firezone_telemetry::Dsn;
use std::time::Duration;

mod make_writer;
mod tun;

// mark:next-android-version
pub const RELEASE: &str = "connlib-android@1.5.6";
// mark:next-android-version
pub const VERSION: &str = "1.5.6";
pub const COMPONENT: &str = "android-client";

/// We have valid use cases for headless Android clients
/// (IoT devices, point-of-sale devices, etc), so try to reconnect for 30 days.
pub const MAX_PARTITION_TIME: Duration = Duration::from_secs(60 * 60 * 24 * 30);

pub const DSN: Dsn = firezone_telemetry::ANDROID_DSN;

pub(crate) use make_writer::MakeWriter;
pub(crate) use tun::Tun;
