use crate::{device_channel::Device, sockets::Sockets, BUF_SIZE};
use futures::{
    future::{self, Either},
    stream, Stream, StreamExt,
};
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
    tun_tx: mpsc::Sender<Box<dyn Tun>>,
    outbound_packet_tx: mpsc::Sender<IpPacket>,
    inbound_packet_rx: mpsc::Receiver<IpPacket>,
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

        let (inbound_packet_tx, inbound_packet_rx) = mpsc::channel(IP_CHANNEL_SIZE);
        let (outbound_packet_tx, outbound_packet_rx) = mpsc::channel(IP_CHANNEL_SIZE);
        let (tun_tx, tun_rx) = mpsc::channel(10);

        std::thread::spawn(|| {
            futures::executor::block_on(tun_send_recv(
                tun_rx,
                outbound_packet_rx,
                inbound_packet_tx,
            ))
        });

        Self {
            tun_tx,
            outbound_packet_tx,
            inbound_packet_rx,
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

        if let Poll::Ready(Some(packet)) = self.inbound_packet_rx.poll_recv(cx) {
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
        // If we can't set a new TUN device, shut down connlib.

        self.tun_tx
            .try_send(tun)
            .expect("Channel to set new TUN device should always have capacity");
    }

    pub fn send_tun(&mut self, packet: IpPacket) -> io::Result<()> {
        let Err(e) = self.outbound_packet_tx.try_send(packet) else {
            return Ok(());
        };

        match e {
            mpsc::error::TrySendError::Full(_) => {
                Err(io::Error::other("Outbound packet channel is at capacity"))
            }
            mpsc::error::TrySendError::Closed(_) => Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "Outbound packet channel is disconnected",
            )),
        }
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

async fn tun_send_recv(
    mut tun_rx: mpsc::Receiver<Box<dyn Tun>>,
    mut outbound_packet_rx: mpsc::Receiver<IpPacket>,
    inbound_packet_tx: mpsc::Sender<IpPacket>,
) {
    let mut device = Device::new();

    let mut command_stream = stream::select_all([
        new_tun_stream(&mut tun_rx),
        outgoing_packet_stream(&mut outbound_packet_rx),
    ]);

    loop {
        match future::select(
            command_stream.next(),
            future::poll_fn(|cx| device.poll_read(cx)),
        )
        .await
        {
            Either::Left((Some(Command::SendPacket(p)), _)) => {
                if let Err(e) = device.write(p) {
                    tracing::debug!("Failed to write TUN packet: {e}");
                };
            }
            Either::Left((Some(Command::UpdateTun(tun)), _)) => {
                device.set_tun(tun);
            }
            Either::Left((None, _)) => {
                tracing::debug!("Command stream closed");
                return;
            }
            Either::Right((Ok(p), _)) => {
                if inbound_packet_tx.send(p).await.is_err() {
                    tracing::debug!("Inbound packet channel closed");
                    return;
                };
            }
            Either::Right((Err(e), _)) => {
                tracing::debug!("Failed to read packet from TUN device: {e}");
                return;
            }
        };
    }
}

#[expect(
    clippy::large_enum_variant,
    reason = "We purposely don't want to allocate each IP packet."
)]
enum Command {
    UpdateTun(Box<dyn Tun>),
    SendPacket(IpPacket),
}

fn new_tun_stream(
    tun_rx: &mut mpsc::Receiver<Box<dyn Tun>>,
) -> Pin<Box<dyn Stream<Item = Command> + '_>> {
    Box::pin(stream::poll_fn(|cx| {
        tun_rx
            .poll_recv(cx)
            .map(|maybe_t| maybe_t.map(Command::UpdateTun))
    }))
}

fn outgoing_packet_stream(
    outbound_packet_rx: &mut mpsc::Receiver<IpPacket>,
) -> Pin<Box<dyn Stream<Item = Command> + '_>> {
    Box::pin(stream::poll_fn(|cx| {
        outbound_packet_rx
            .poll_recv(cx)
            .map(|maybe_p| maybe_p.map(Command::SendPacket))
    }))
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
