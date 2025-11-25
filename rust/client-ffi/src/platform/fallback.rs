use std::{io, os::fd::RawFd, time::Duration};

use telemetry::Dsn;

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
    fn poll_send_ready(&mut self, _: &mut std::task::Context) -> std::task::Poll<io::Result<()>> {
        todo!()
    }

    fn send(&mut self, _: ip_packet::IpPacket) -> io::Result<()> {
        todo!()
    }

    fn poll_recv_many(
        &mut self,
        _: &mut std::task::Context,
        _: &mut Vec<ip_packet::IpPacket>,
        _: usize,
    ) -> std::task::Poll<usize> {
        todo!()
    }

    fn name(&self) -> &str {
        todo!()
    }
}
