use std::io;

pub(crate) struct MakeWriter {
    oslog: oslog::OsLog,
}

pub(crate) struct Writer<'l> {
    level: tracing::Level,
    oslog: &'l oslog::OsLog,
}

impl MakeWriter {
    pub(crate) fn new(subsystem: &'static str, category: &'static str) -> Self {
        Self {
            oslog: oslog::new(subsystem, category),
        }
    }

    fn make_writer_for_level(&self, level: tracing::Level) -> Writer<'_> {
        Writer {
            level,
            oslog: &self.oslog,
        }
    }
}

impl<'l> tracing_subscriber::fmt::MakeWriter<'l> for MakeWriter {
    type Writer = Writer<'l>;

    fn make_writer(&'l self) -> Self::Writer {
        self.make_writer_for_level(tracing::Level::INFO)
    }

    fn make_writer_for(&'l self, meta: &tracing::Metadata<'_>) -> Self::Writer {
        self.make_writer_for_level(*meta.level())
    }
}

impl io::Write for Writer<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let message = std::str::from_utf8(buf).map_err(io::Error::other)?;

        self.oslog.with_level(self.level, message);

        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod oslog {
    pub struct OsLog {
        inner: ::oslog::OsLog,
    }

    impl OsLog {
        pub fn with_level(&self, level: tracing::Level, msg: &str) {
            self.inner.with_level(
                match level {
                    tracing::Level::TRACE => ::oslog::Level::Debug,
                    tracing::Level::DEBUG => ::oslog::Level::Info,
                    tracing::Level::INFO => ::oslog::Level::Default,
                    tracing::Level::WARN => ::oslog::Level::Error,
                    tracing::Level::ERROR => ::oslog::Level::Fault,
                },
                msg,
            )
        }
    }

    pub fn new(subsystem: &'static str, category: &'static str) -> OsLog {
        OsLog {
            inner: ::oslog::OsLog::new(subsystem, category),
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
mod oslog {
    pub struct OsLog {}

    impl OsLog {
        pub fn with_level(&self, _: tracing::Level, _: &str) {
            unimplemented!("Stub should never be called")
        }
    }

    pub fn new(_: &'static str, _: &'static str) -> OsLog {
        unimplemented!("Stub should never be called")
    }
}
