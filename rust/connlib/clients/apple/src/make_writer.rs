//! Heavily inspired from https://github.com/Actyx/tracing-android/blob/master/src/android.rs.

use oslog::OsLog;
use std::{
    ffi::{CStr, CString},
    io::{self, BufWriter},
};
use tracing::Level;

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

    fn make_writer_for_level(&self, level: Level) -> BufWriter<Writer<'_>> {
        let inner = Writer {
            level: match level {
                Level::TRACE => oslog::Level::Debug,
                Level::DEBUG => oslog::Level::Info,
                Level::INFO => oslog::Level::Default,
                Level::WARN => oslog::Level::Error,
                Level::ERROR => oslog::Level::Fault,
            },
            oslog: &self.oslog,
        };

        BufWriter::with_capacity(LOGGING_MSG_MAX_LEN, inner)
    }
}

impl<'l> tracing_subscriber::fmt::MakeWriter<'l> for MakeWriter {
    type Writer = BufWriter<Writer<'l>>;

    fn make_writer(&self) -> Self::Writer {
        self.make_writer_for_level(Level::INFO)
    }

    fn make_writer_for(&self, meta: &tracing::Metadata<'_>) -> Self::Writer {
        self.make_writer_for_level(*meta.level())
    }
}

impl io::Write for Writer {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let message = std::str::from_utf8(buf)?;

        self.oslog.with_level(self.level, message);

        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
