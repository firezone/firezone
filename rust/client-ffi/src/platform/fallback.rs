use std::{io, time::Duration};

use telemetry::Dsn;

use crate::fd::RawFd;

pub const RELEASE: &str = "";
pub const VERSION: &str = "";
pub const COMPONENT: &str = "";

pub const DSN: Dsn = telemetry::TESTING;

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

pub struct Tun;

impl Tun {
    pub unsafe fn from_fd(_: RawFd, _: &tokio::runtime::Handle) -> io::Result<Self> {
        Err(io::Error::other("Stub!"))
    }
}

impl tun::Tun for Tun {
    fn sender(&self) -> &tun::OutboundTx {
        todo!()
    }

    fn receiver(&mut self) -> &mut tun::InboundRx {
        todo!()
    }

    fn name(&self) -> &str {
        todo!()
    }
}
