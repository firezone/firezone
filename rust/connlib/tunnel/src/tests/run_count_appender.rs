use std::sync::atomic::AtomicU32;
use tracing_appender::rolling::RollingFileAppender;

/// A file appender that rolls over to a new file for every instance that is created within the same process.
#[allow(dead_code)]
pub(crate) fn appender() -> RollingFileAppender {
    static RUN_COUNT: AtomicU32 = AtomicU32::new(0);
    let run_count = RUN_COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

    tracing_appender::rolling::never(".", format!("run_{run_count:04}.log"))
}
