use std::time::Duration;
use telemetry::Dsn;

mod make_writer;
mod tun;

// mark:next-apple-version
pub const RELEASE: &str = "connlib-apple@1.5.12";

// mark:next-apple-version
pub const VERSION: &str = "1.5.12";

pub const COMPONENT: &str = "apple-client";

/// The Apple client implements reconnect logic in the upper layer using OS provided
/// APIs to detect network connectivity changes. The reconnect timeout here only
/// applies only in the following conditions:
///
/// * That reconnect logic fails to detect network changes (not expected to happen)
/// * The portal is DOWN
///
/// Hopefully we aren't down for more than 24 hours.
pub const MAX_PARTITION_TIME: Duration = Duration::from_secs(60 * 60 * 24);

pub const DSN: Dsn = telemetry::APPLE_DSN;

pub(crate) use make_writer::MakeWriter;
pub(crate) use tun::Tun;
