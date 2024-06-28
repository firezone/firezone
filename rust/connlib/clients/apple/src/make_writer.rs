//! Heavily inspired from https://github.com/Actyx/tracing-android/blob/master/src/android.rs.

use oslog::OsLog;
use std::io;

const LOGGING_MSG_MAX_LEN: usize = 4000;

pub(crate) struct MakeWriter {
    oslog: OsLog,
}

pub(crate) struct Writer<'l> {
    level: oslog::Level,
    oslog: &'l OsLog,
}

impl MakeWriter {
    pub(crate) fn new(subsystem: &'static str, category: &'static str) -> Self {
        Self {
            oslog: OsLog::new(subsystem, category),
        }
    }

    fn make_writer_for_level(&self, level: tracing::Level) -> Writer<'_> {
        Writer {
            level: match level {
                tracing::Level::TRACE => oslog::Level::Debug,
                tracing::Level::DEBUG => oslog::Level::Info,
                tracing::Level::INFO => oslog::Level::Default,
                tracing::Level::WARN => oslog::Level::Error,
                tracing::Level::ERROR => oslog::Level::Fault,
            },
            oslog: &self.oslog,
        }
    }
}

impl<'l> tracing_subscriber::fmt::MakeWriter<'l> for MakeWriter {
    type Writer = Writer<'l>;

    fn make_writer(&self) -> Self::Writer {
        self.make_writer_for_level(tracing::Level::INFO)
    }

    fn make_writer_for(&self, meta: &tracing::Metadata<'_>) -> Self::Writer {
        self.make_writer_for_level(*meta.level())
    }
}

impl<'l> io::Write for Writer<'l> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let message =
            std::str::from_utf8(buf).map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;

        self.oslog.with_level(self.level, message);

        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
