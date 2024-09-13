use crate::{device_channel::Device, sockets::Sockets, BUF_SIZE};
use futures::future::{self, Either};
use futures_util::FutureExt as _;
use ip_packet::IpPacket;
use snownet::{EncryptBuffer, EncryptedPacket};
use socket_factory::{DatagramIn, DatagramOut, SocketFactory, TcpSocket, UdpSocket};
use std::{
    io,
    pin::Pin,
    sync::Arc,
    task::{ready, Context, Poll},
    time::Instant,
};
use tokio::sync::mpsc;
use tun::Tun;

/// Bundles together all side-effects that connlib needs to have access to.
pub struct Io {
    /// The UDP sockets used to send & receive packets from the network.
    sockets: Sockets,
    unwritten_packet: Option<EncryptedPacket>,

    _tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,

    timeout: Option<Pin<Box<tokio::time::Sleep>>>,
    outbound_packet_sender: mpsc::Sender<TunMsg>,
    inbound_packet_receiver: mpsc::Receiver<IpPacket>,
}

#[expect(
    clippy::large_enum_variant,
    reason = "We purposely don't want to allocate each IP packet."
)]
pub enum Input<I> {
    Timeout(Instant),
    Device(IpPacket),
    Network(I),
}

#[expect(
    clippy::large_enum_variant,
    reason = "We purposely don't want to allocate each IP packet."
)]
enum TunMsg {
    Packet(IpPacket),
    NewTun(Box<dyn Tun>),
}

const IP_CHANNEL_SIZE: usize = 1000;

impl Io {
    /// Creates a new I/O abstraction
    ///
    /// Must be called within a Tokio runtime context so we can bind the sockets.
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    ) -> Self {
        let mut sockets = Sockets::default();
        sockets.rebind(udp_socket_factory.as_ref()); // Bind sockets on startup. Must happen within a tokio runtime context.

        let (inbound_packet_sender, inbound_packet_receiver) = mpsc::channel(IP_CHANNEL_SIZE);
        let (outbound_packet_sender, mut outbound_packet_receiver) = mpsc::channel(IP_CHANNEL_SIZE);

        std::thread::spawn(|| {
            futures::executor::block_on(async move {
                let mut device = Device::new();

                loop {
                    match future::select(
                        std::future::poll_fn(|cx| device.poll_read(cx)),
                        std::pin::pin!(outbound_packet_receiver.recv()),
                    )
                    .await
                    {
                        Either::Left((Ok(packet), _)) => {
                            match inbound_packet_sender.send(packet).await {
                                Ok(()) => {}
                                Err(_) => {
                                    tracing::warn!("Inbound packet channel is closed");
                                    return;
                                }
                            };
                        }
                        Either::Left((Err(e), _)) => {
                            tracing::debug!("Failed to read packet from TUN device: {e}")
                        }
                        Either::Right((Some(TunMsg::NewTun(tun)), _)) => {
                            device.set_tun(tun);
                        }
                        Either::Right((Some(TunMsg::Packet(packet)), _)) => {
                            match device.write(packet) {
                                Ok(_) => {}
                                Err(e) => {
                                    tracing::debug!("Failed to write packet to TUN interface: {e}");
                                }
                            }
                        }
                        Either::Right((None, _)) => {
                            tracing::warn!("Outbound packet channel is closed");
                            return;
                        }
                    }
                }
            })
        });

        Self {
            outbound_packet_sender,
            inbound_packet_receiver,
            timeout: None,
            sockets,
            _tcp_socket_factory: tcp_socket_factory,
            udp_socket_factory,
            unwritten_packet: None,
        }
    }

    pub fn poll_has_sockets(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.sockets.poll_has_sockets(cx)
    }

    pub fn poll<'b>(
        &mut self,
        cx: &mut Context<'_>,
        ip4_buffer: &'b mut [u8],
        ip6_bffer: &'b mut [u8],
        encrypt_buffer: &EncryptBuffer,
    ) -> Poll<io::Result<Input<impl Iterator<Item = DatagramIn<'b>>>>> {
        ready!(self.poll_send_unwritten(cx, encrypt_buffer)?);

        if let Poll::Ready(network) = self.sockets.poll_recv_from(ip4_buffer, ip6_bffer, cx)? {
            return Poll::Ready(Ok(Input::Network(network.filter(is_max_wg_packet_size))));
        }

        if let Poll::Ready(Some(packet)) = self.inbound_packet_receiver.poll_recv(cx) {
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

    fn poll_send_unwritten(
        &mut self,
        cx: &mut Context<'_>,
        buf: &EncryptBuffer,
    ) -> Poll<io::Result<()>> {
        ready!(self.sockets.poll_send_ready(cx))?;

        // If the `unwritten_packet` is set, `EncryptBuffer` is still holding a packet that we need so send.
        let Some(unwritten_packet) = self.unwritten_packet.take() else {
            return Poll::Ready(Ok(()));
        };

        self.send_encrypted_packet(unwritten_packet, buf)?;

        Poll::Ready(Ok(()))
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.outbound_packet_sender
            .try_send(TunMsg::NewTun(tun))
            .unwrap(); // TODO: Maybe we need two channels for proper back-pressure?
    }

    pub fn send_tun(&mut self, packet: IpPacket) {
        let _ = self.outbound_packet_sender.try_send(TunMsg::Packet(packet));
    }

    pub fn rebind_sockets(&mut self) {
        self.sockets.rebind(self.udp_socket_factory.as_ref());
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

    pub fn send_encrypted_packet(
        &mut self,
        packet: EncryptedPacket,
        buf: &EncryptBuffer,
    ) -> io::Result<()> {
        let transmit = packet.to_transmit(buf);
        let res = self.send_network(transmit);

        if res
            .as_ref()
            .err()
            .is_some_and(|e| e.kind() == io::ErrorKind::WouldBlock)
        {
            tracing::debug!(dst = %packet.dst(), "Socket busy");
            self.unwritten_packet = Some(packet);
        }

        res?;

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn max_ip_channel_size_is_reasonable() {
        let one_ip_packet = std::mem::size_of::<IpPacket>();
        let max_channel_size = IP_CHANNEL_SIZE * one_ip_packet;

        assert_eq!(max_channel_size, 1_360_000); // 1.36MB is fine, we only have 2 of these channels, meaning less than 3MB additional buffer in total.
    }
}
