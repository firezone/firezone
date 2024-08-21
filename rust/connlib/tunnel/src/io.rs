use crate::{
    device_channel::Device,
    sockets::{NoInterfaces, Sockets},
    BUF_SIZE,
};
use futures_util::FutureExt as _;
use ip_packet::{IpPacket, MutableIpPacket};
use socket_factory::{DatagramIn, DatagramOut, SocketFactory, TcpSocket, UdpSocket};
use std::{
    io,
    pin::Pin,
    sync::Arc,
    task::{ready, Context, Poll},
    time::Instant,
};

/// Bundles together all side-effects that connlib needs to have access to.
pub struct Io {
    /// The TUN device offered to the user.
    ///
    /// This is the `tun-firezone` network interface that users see when they e.g. type `ip addr` on Linux.
    device: Device,
    /// The UDP sockets used to send & receive packets from the network.
    sockets: Sockets,

    _tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,

    timeout: Option<Pin<Box<tokio::time::Sleep>>>,
}

pub enum Input<'a, I> {
    Timeout(Instant),
    Device(MutableIpPacket<'a>),
    Network(I),
}

impl Io {
    /// Creates a new I/O abstraction
    ///
    /// Must be called within a Tokio runtime context so we can bind the sockets.
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    ) -> Result<Self, NoInterfaces> {
        let mut sockets = Sockets::default();
        sockets.rebind(udp_socket_factory.as_ref())?; // Bind sockets on startup. Must happen within a tokio runtime context.

        Ok(Self {
            device: Device::new(),
            timeout: None,
            sockets,
            _tcp_socket_factory: tcp_socket_factory,
            udp_socket_factory,
        })
    }

    pub fn poll<'b1, 'b2>(
        &mut self,
        cx: &mut Context<'_>,
        ip4_buffer: &'b1 mut [u8],
        ip6_bffer: &'b1 mut [u8],
        device_buffer: &'b2 mut [u8],
    ) -> Poll<io::Result<Input<'b2, impl Iterator<Item = DatagramIn<'b1>>>>> {
        if let Poll::Ready(network) = self.sockets.poll_recv_from(ip4_buffer, ip6_bffer, cx)? {
            return Poll::Ready(Ok(Input::Network(network.filter(is_max_wg_packet_size))));
        }

        ready!(self.sockets.poll_flush(cx))?;

        if let Poll::Ready(packet) = self.device.poll_read(device_buffer, cx)? {
            return Poll::Ready(Ok(Input::Device(packet)));
        }

        if let Some(timeout) = self.timeout.as_mut() {
            if timeout.poll_unpin(cx).is_ready() {
                let deadline = timeout.deadline().into();
                self.timeout.as_mut().take(); // Clear the timeout.

                return Poll::Ready(Ok(Input::Timeout(deadline)));
            }
        }

        Poll::Pending
    }

    pub fn device_mut(&mut self) -> &mut Device {
        &mut self.device
    }

    pub fn rebind_sockets(&mut self) -> Result<(), NoInterfaces> {
        self.sockets.rebind(self.udp_socket_factory.as_ref())?;

        Ok(())
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

    pub fn send_network(&mut self, transmit: snownet::Transmit) -> io::Result<()> {
        self.sockets.send(DatagramOut {
            src: transmit.src,
            dst: transmit.dst,
            packet: transmit.payload,
        })?;

        Ok(())
    }

    pub fn send_device(&self, packet: IpPacket<'_>) -> io::Result<()> {
        self.device.write(packet)?;

        Ok(())
    }
}

fn is_max_wg_packet_size(d: &DatagramIn) -> bool {
    let len = d.packet.len();
    if len > BUF_SIZE {
        tracing::debug!(from = %d.from, %len, "Dropping too large datagram (max allowed: {BUF_SIZE} bytes)");

        return false;
    }

    true
}
