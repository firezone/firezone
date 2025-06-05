use std::{io, time::Duration};

use firezone_telemetry::Dsn;

pub const RELEASE: &str = "";
pub const VERSION: &str = "";

pub const DSN: Dsn = firezone_telemetry::TESTING;

pub const MAX_PARTITION_TIME: Duration = Duration::ZERO;

#[derive(Default)]
pub struct MakeWriter {}

pub struct DevNull;

impl tracing_subscriber::fmt::MakeWriter<'_> for MakeWriter {
    type Writer = DevNull;

    fn make_writer(&self) -> Self::Writer {
        DevNull
    }

    fn make_writer_for(&self, _: &tracing::Metadata<'_>) -> Self::Writer {
        DevNull
    }
}

impl io::Write for DevNull {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
