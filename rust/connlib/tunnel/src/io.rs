use crate::{
    device_channel::Device,
    ip_packet::{IpPacket, MutableIpPacket},
    sockets::{Received, Sockets},
};
use futures_util::FutureExt as _;
use snownet::Transmit;
use std::{
    io,
    pin::Pin,
    task::{ready, Context, Poll},
    time::Instant,
};

pub struct Io {
    device: Device,
    timeout: Option<Pin<Box<tokio::time::Sleep>>>,
    sockets: Sockets,
}

pub enum Input<'a, I> {
    Timeout(Instant),
    Device(MutableIpPacket<'a>),
    Network(I),
}

impl Io {
    pub fn new() -> io::Result<Self> {
        Ok(Self {
            device: Device::new(),
            timeout: None,
            sockets: Sockets::new()?,
        })
    }

    pub fn poll<'b>(
        &mut self,
        cx: &mut Context<'_>,
        buffer: &'b mut [u8],
    ) -> Poll<io::Result<Input<'b, impl Iterator<Item = Received<'b>>>>> {
        let (buf1, buf2) = buffer.split_at_mut(buffer.len() / 2); // If rustc borrow-checker would be better, we wouldn't need

        if let Some(timeout) = self.timeout.as_mut() {
            if timeout.poll_unpin(cx).is_ready() {
                return Poll::Ready(Ok(Input::Timeout(timeout.deadline().into())));
            }
        }

        if let Poll::Ready(network) = self.sockets.poll_recv_from(buf1, cx)? {
            return Poll::Ready(Ok(Input::Network(network)));
        }

        ready!(self.sockets.poll_send_ready(cx))?; // Packets read from the device need to be written to a socket, let's make sure the socket can take more packets.

        if let Poll::Ready(packet) = self.device.poll_read(buf2, cx)? {
            return Poll::Ready(Ok(Input::Device(packet)));
        }

        Poll::Pending
    }

    pub fn device_mut(&mut self) -> &mut Device {
        &mut self.device
    }

    pub fn sockets_ref(&self) -> &Sockets {
        &self.sockets
    }

    pub fn reset_timeout(&mut self, timeout: Instant) {
        let timeout = tokio::time::Instant::from_std(timeout);

        match self.timeout.as_mut() {
            Some(existing_timeout) if existing_timeout.deadline() != timeout => {
                existing_timeout.as_mut().reset(timeout)
            }
            Some(_) => {}
            None => self.timeout = Some(Box::pin(tokio::time::sleep_until(timeout))),
        }
    }

    pub fn send_network(&self, transmit: Transmit) -> io::Result<()> {
        self.sockets.try_send(&transmit)?;

        Ok(())
    }

    pub fn send_device(&self, packet: IpPacket<'_>) -> io::Result<()> {
        self.device.write(packet)?;

        Ok(())
    }
}
