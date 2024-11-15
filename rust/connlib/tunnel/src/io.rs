mod gso_queue;

use crate::{device_channel::Device, dns, sockets::Sockets};
use domain::base::Message;
use firezone_logging::{err_with_src, telemetry_event, telemetry_span};
use futures::{
    future::{self, Either},
    stream, Stream, StreamExt,
};
use futures_bounded::FuturesTupleSet;
use futures_util::FutureExt as _;
use gso_queue::GsoQueue;
use ip_packet::{IpPacket, MAX_DATAGRAM_PAYLOAD};
use socket_factory::{DatagramIn, SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::VecDeque,
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    pin::Pin,
    sync::Arc,
    task::{ready, Context, Poll},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::mpsc,
};
use tokio_util::sync::PollSender;
use tracing::Instrument;
use tun::Tun;

/// How many IP packets we will at most read from the MPSC-channel connected to our TUN device thread.
///
/// Reading IP packets from the channel in batches allows us to process (i.e. encrypt) them as a batch.
/// UDP datagrams of the same size and destination can then be sent in a single syscall using GSO.
const MAX_INBOUND_PACKET_BATCH: usize = 50;
const MAX_UDP_SIZE: usize = (1 << 16) - 1;

/// Bundles together all side-effects that connlib needs to have access to.
pub struct Io {
    /// The UDP sockets used to send & receive packets from the network.
    sockets: Sockets,
    gso_queue: GsoQueue,

    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,

    dns_queries: FuturesTupleSet<io::Result<Message<Vec<u8>>>, DnsQueryMetaData>,

    timeout: Option<Pin<Box<tokio::time::Sleep>>>,

    tun_tx: mpsc::Sender<Box<dyn Tun>>,
    outbound_packet_buffer: VecDeque<IpPacket>,
    outbound_packet_tx: PollSender<IpPacket>,
    inbound_packet_rx: mpsc::Receiver<IpPacket>,
}

#[derive(Debug)]
struct DnsQueryMetaData {
    query: Message<Vec<u8>>,
    server: SocketAddr,
    transport: dns::Transport,
}

pub(crate) struct Buffers {
    ip: Vec<IpPacket>,
    udp4: Vec<u8>,
    udp6: Vec<u8>,
}

impl Default for Buffers {
    fn default() -> Self {
        Self {
            ip: Vec::with_capacity(MAX_INBOUND_PACKET_BATCH),
            udp4: Vec::from([0; MAX_UDP_SIZE]),
            udp6: Vec::from([0; MAX_UDP_SIZE]),
        }
    }
}

pub enum Input<D, I> {
    Timeout(Instant),
    Device(D),
    Network(I),
    DnsResponse(dns::RecursiveResponse),
}

const DNS_QUERY_TIMEOUT: Duration = Duration::from_secs(5);
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

        std::thread::Builder::new()
            .name("connlib-tun-send-recv".to_string())
            .spawn(|| {
                futures::executor::block_on(tun_send_recv(
                    tun_rx,
                    outbound_packet_rx,
                    inbound_packet_tx,
                ))
            })
            .expect("Failed to spawn tun_send_recv thread");

        Self {
            tun_tx,
            outbound_packet_buffer: VecDeque::with_capacity(10), // It is unlikely that we process more than 10 packets after 1 GRO call.
            outbound_packet_tx: PollSender::new(outbound_packet_tx),
            inbound_packet_rx,
            timeout: None,
            sockets,
            tcp_socket_factory,
            udp_socket_factory,
            dns_queries: FuturesTupleSet::new(DNS_QUERY_TIMEOUT, 1000),
            gso_queue: GsoQueue::new(socket_factory::MAX_GSO_SEGMENTS),
        }
    }

    pub fn poll_has_sockets(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.sockets.poll_has_sockets(cx)
    }

    pub fn poll<'b>(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &'b mut Buffers,
    ) -> Poll<
        io::Result<
            Input<impl Iterator<Item = IpPacket> + use<'b>, impl Iterator<Item = DatagramIn<'b>>>,
        >,
    > {
        ready!(self.flush_send_queue(cx)?);

        if let Poll::Ready(network) =
            self.sockets
                .poll_recv_from(&mut buffers.udp4, &mut buffers.udp6, cx)?
        {
            return Poll::Ready(Ok(Input::Network(network.filter(is_max_wg_packet_size))));
        }

        if let Poll::Ready(num_packets) =
            self.inbound_packet_rx
                .poll_recv_many(cx, &mut buffers.ip, MAX_INBOUND_PACKET_BATCH)
        {
            if num_packets > 0 {
                return Poll::Ready(Ok(Input::Device(buffers.ip.drain(..num_packets))));
            }
        }

        match self.dns_queries.poll_unpin(cx) {
            Poll::Ready((result, meta)) => {
                let response = match result {
                    Ok(result) => dns::RecursiveResponse {
                        server: meta.server,
                        query: meta.query,
                        message: result,
                        transport: meta.transport,
                    },
                    Err(e @ futures_bounded::Timeout { .. }) => dns::RecursiveResponse {
                        server: meta.server,
                        query: meta.query,
                        message: Err(io::Error::new(io::ErrorKind::TimedOut, e)),
                        transport: meta.transport,
                    },
                };

                return Poll::Ready(Ok(Input::DnsResponse(response)));
            }
            Poll::Pending => {}
        }

        if let Some(timeout) = self.timeout.as_mut() {
            if timeout.poll_unpin(cx).is_ready() {
                let deadline = timeout.deadline().into();
                self.timeout = None; // Clear the timeout.

                // Piggy back onto the timeout we already have.
                // It is not important when we call this, just needs to be called occasionally.
                self.gso_queue.handle_timeout(deadline);

                return Poll::Ready(Ok(Input::Timeout(deadline)));
            }
        }

        Poll::Pending
    }

    fn flush_send_queue(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let mut datagrams = self.gso_queue.datagrams();

        loop {
            ready!(self.sockets.poll_send_ready(cx))?;

            let Some(datagram) = datagrams.next() else {
                break;
            };

            self.sockets.send(datagram)?;
        }

        loop {
            // First, acquire a slot in the channel.
            ready!(self
                .outbound_packet_tx
                .poll_reserve(cx)
                .map_err(|_| io::ErrorKind::BrokenPipe)?);

            // Second, check if we have any buffer packets.
            let Some(packet) = self.outbound_packet_buffer.pop_front() else {
                break; // No more packets? All done.
            };

            // Third, send the packet.
            self.outbound_packet_tx
                .send_item(packet)
                .map_err(|_| io::ErrorKind::BrokenPipe)?;
        }

        Poll::Ready(Ok(()))
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        // If we can't set a new TUN device, shut down connlib.

        self.tun_tx
            .try_send(tun)
            .expect("Channel to set new TUN device should always have capacity");
    }

    pub fn send_tun(&mut self, packet: IpPacket) {
        self.outbound_packet_buffer.push_back(packet);
    }

    pub fn rebind_sockets(&mut self) {
        self.sockets.rebind(self.udp_socket_factory.as_ref());
        self.gso_queue.clear();
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

    pub fn send_network(&mut self, src: Option<SocketAddr>, dst: SocketAddr, payload: &[u8]) {
        self.gso_queue.enqueue(src, dst, payload, Instant::now())
    }

    pub fn send_dns_query(&mut self, query: dns::RecursiveQuery) {
        match query.transport {
            dns::Transport::Udp { .. } => {
                let factory = self.udp_socket_factory.clone();
                let server = query.server;
                let bind_addr = match query.server {
                    SocketAddr::V4(_) => SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
                    SocketAddr::V6(_) => SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
                };
                let meta = DnsQueryMetaData {
                    query: query.message.clone(),
                    server,
                    transport: query.transport,
                };

                if self
                    .dns_queries
                    .try_push(
                        async move {
                            // To avoid fragmentation, IP and thus also UDP packets can only reliably sent with an MTU of <= 1500 on the public Internet.
                            const BUF_SIZE: usize = 1500;

                            let udp_socket = factory(&bind_addr)?;

                            let response = udp_socket
                                .handshake::<BUF_SIZE>(server, query.message.as_slice())
                                .await?;

                            let message = Message::from_octets(response)
                                .map_err(|_| io::Error::other("Failed to parse DNS message"))?;

                            Ok(message)
                        }
                        .instrument(telemetry_span!("recursive_udp_dns_query")),
                        meta,
                    )
                    .is_err()
                {
                    tracing::debug!("Failed to queue UDP DNS query")
                }
            }
            dns::Transport::Tcp { .. } => {
                let factory = self.tcp_socket_factory.clone();
                let server = query.server;
                let meta = DnsQueryMetaData {
                    query: query.message.clone(),
                    server,
                    transport: query.transport,
                };

                if self
                    .dns_queries
                    .try_push(
                        async move {
                            let tcp_socket = factory(&server)?; // TODO: Optimise this to reuse a TCP socket to the same resolver.
                            let mut tcp_stream = tcp_socket.connect(server).await?;

                            let query = query.message.into_octets();
                            let dns_message_length = (query.len() as u16).to_be_bytes();

                            tcp_stream.write_all(&dns_message_length).await?;
                            tcp_stream.write_all(&query).await?;

                            let mut response_length = [0u8; 2];
                            tcp_stream.read_exact(&mut response_length).await?;
                            let response_length = u16::from_be_bytes(response_length) as usize;

                            // A u16 is at most 65k, meaning we are okay to allocate here based on what the remote is sending.
                            let mut response = vec![0u8; response_length];
                            tcp_stream.read_exact(&mut response).await?;

                            let message = Message::from_octets(response)
                                .map_err(|_| io::Error::other("Failed to parse DNS message"))?;

                            Ok(message)
                        }
                        .instrument(telemetry_span!("recursive_tcp_dns_query")),
                        meta,
                    )
                    .is_err()
                {
                    tracing::debug!("Failed to queue TCP DNS query")
                }
            }
        }
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
                    tracing::debug!("Failed to write TUN packet: {}", err_with_src(&e));
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
                tracing::debug!(
                    "Failed to read packet from TUN device: {}",
                    err_with_src(&e)
                );
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
    if len > MAX_DATAGRAM_PAYLOAD {
        telemetry_event!(from = %d.from, %len, "Dropping too large datagram (max allowed: {MAX_DATAGRAM_PAYLOAD} bytes)");

        return false;
    }

    true
}

#[cfg(test)]
mod tests {
    use futures::task::noop_waker_ref;
    use std::{future::poll_fn, ptr::addr_of_mut};

    use super::*;

    #[test]
    fn max_ip_channel_size_is_reasonable() {
        let one_ip_packet = std::mem::size_of::<IpPacket>();
        let max_channel_size = IP_CHANNEL_SIZE * one_ip_packet;

        assert_eq!(max_channel_size, 1_360_000); // 1.36MB is fine, we only have 2 of these channels, meaning less than 3MB additional buffer in total.
    }

    #[tokio::test]
    async fn timer_is_reset_after_it_fires() {
        let now = Instant::now();

        let mut io = Io::new(
            Arc::new(|_| Err(io::Error::other("not implemented"))),
            Arc::new(|_| Err(io::Error::other("not implemented"))),
        );

        io.reset_timeout(now + Duration::from_secs(1));

        let poll_fn = poll_fn(|cx| {
            io.poll(
                cx,
                // SAFETY: This is a test and we never receive packets here.
                unsafe { &mut *addr_of_mut!(DUMMY_BUF) },
            )
        })
        .await
        .unwrap();

        let Input::Timeout(timeout) = poll_fn else {
            panic!("Unexpected result");
        };

        assert_eq!(timeout, now + Duration::from_secs(1));

        let poll = io.poll(
            &mut Context::from_waker(noop_waker_ref()),
            // SAFETY: This is a test and we never receive packets here.
            unsafe { &mut *addr_of_mut!(DUMMY_BUF) },
        );

        assert!(poll.is_pending());
        assert!(io.timeout.is_none());
    }

    static mut DUMMY_BUF: Buffers = Buffers {
        ip: Vec::new(),
        udp4: Vec::new(),
        udp6: Vec::new(),
    };
}
