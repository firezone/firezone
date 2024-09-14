use ip_packet::IpPacket;
use std::io;
use std::task::{Context, Poll, Waker};
use tun::Tun;

pub struct Device {
    tun: Option<Box<dyn Tun>>,
    waker: Option<Waker>,
}

impl Device {
    pub(crate) fn new() -> Self {
        Self {
            tun: None,
            waker: None,
        }
    }

    pub(crate) fn set_tun(&mut self, tun: Box<dyn Tun>) {
        tracing::info!(name = %tun.name(), "Initializing TUN device");

        self.tun = Some(tun);

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub(crate) fn poll_read(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<IpPacket>> {
        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };

        let mut buf = [0u8; ip_packet::MAX_IP_SIZE];

        let n = std::task::ready!(tun.poll_read(&mut buf[20..], cx))?;

        if n == 0 {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "device is closed",
            )));
        }

        let packet = IpPacket::new(buf, 20, n).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "received bytes are not an IP packet",
            )
        })?;

        tracing::trace!(target: "wire::dev::recv", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());

        Poll::Ready(Ok(packet))
    }

    pub fn write(&self, packet: IpPacket) -> io::Result<usize> {
        tracing::trace!(target: "wire::dev::send", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());

        match packet {
            IpPacket::Ipv4(msg) => self.tun()?.write4(msg.packet()),
            IpPacket::Ipv6(msg) => self.tun()?.write6(msg.packet()),
        }
    }

    fn tun(&self) -> io::Result<&dyn Tun> {
        Ok(self
            .tun
            .as_ref()
            .ok_or_else(io_error_not_initialized)?
            .as_ref())
    }
}

fn io_error_not_initialized() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "device is not initialized yet")
}
