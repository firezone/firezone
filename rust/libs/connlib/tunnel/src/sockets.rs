use crate::otel;
use anyhow::{Context as _, Result};
use bufferpool::{Buffer, BufferPool, VecBuf};
use futures::{FutureExt as _, ready};
use socket_factory::{DatagramBatch, DatagramOut, PerfUdpSocket, SocketFactory, UdpSocket};
use std::collections::VecDeque;
use std::env::VarError;
use std::rc::Rc;
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
use std::sync::LazyLock;
use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    sync::Arc,
    task::{Context, Poll},
};

const DEFAULT_LISTEN_PORT: u16 = EPHEMERAL_PORT_RANGE_START + FIRE;
const EPHEMERAL_PORT_RANGE_START: u16 = 49152;
const FIRE: u16 = 3473; // "FIRE" when typed on a phone pad.
/// How many incoming UDP batches the event-loop reads from each socket per poll.
///
/// A batch is one `recv_from`: `quinn-udp` reads up to `BATCH_SIZE` (32 on unix) datagrams in a single
/// syscall, and where GRO is available the kernel additionally coalesces up to 64 datagrams into each.
/// So both the memory a batch pins ([`socket_factory::MAX_RECV_BATCH_MEMORY`]) and the datagrams it
/// carries swing with GRO: `1316 * 32 * 64` ~ 2.5 MB on Android (GRO), `1316 * 32` ~ 45 KB on Apple.
/// Apple - iOS and macOS alike - has no GRO (`recvmsg_x` only batches individual datagrams), so it
/// drains many of these small batches per poll to sustain throughput, which is cheap. Android's GRO
/// batches are large, so it drains a single one per poll to hold the inbound budget down. Other desktop
/// platforms aren't memory-capped, so a moderate limit already saturates them.
const UDP_RECV_BATCH_LIMIT: usize = cfg_select! {
    target_os = "ios" => { 32 }
    target_os = "macos" => { 32 }
    target_os = "android" => { 1 }
    _ => { 8 }
};

/// Pool for the `Vec`s that collect one poll's worth of received datagram batches.
///
/// Sized to hold a full drain of both sockets, so collecting into it never reallocates.
/// Dropping the collection after processing returns it to the pool, keeping the
/// receive path free of allocations.
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
static BATCHES_POOL: LazyLock<BufferPool<VecBuf<DatagramBatch>>> =
    LazyLock::new(|| BufferPool::new(2 * UDP_RECV_BATCH_LIMIT, "udp-recv-batches"));
#[cfg(any(target_os = "linux", target_os = "macos"))]
thread_local! {
    static BATCHES_POOL: BufferPool<VecBuf<DatagramBatch>> = BufferPool::new(2 * UDP_RECV_BATCH_LIMIT, "udp-recv-batches");
}

fn batches_pool_pull() -> bufferpool::Buffer<VecBuf<DatagramBatch>> {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        BATCHES_POOL.with(|pool| pool.pull())
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        BATCHES_POOL.pull()
    }
}

const UNSPECIFIED_V4_SOCKET: SocketAddrV4 =
    SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, DEFAULT_LISTEN_PORT);
const UNSPECIFIED_V6_SOCKET: SocketAddrV6 =
    SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, DEFAULT_LISTEN_PORT, 0, 0);

#[derive(Default)]
pub(crate) struct Sockets {
    socket_v4: Option<LocalUdpSocket>,
    socket_v6: Option<LocalUdpSocket>,

    /// Bind failures, surfaced through [`Sockets::poll_error`] alongside runtime socket errors.
    bind_errors: VecDeque<anyhow::Error>,
}

impl Sockets {
    pub fn rebind(&mut self, socket_factory: Arc<dyn SocketFactory<UdpSocket>>) {
        self.socket_v4 = None;
        self.socket_v6 = None;

        self.socket_v4 = self.bind(&socket_factory, SocketAddr::V4(UNSPECIFIED_V4_SOCKET));
        self.socket_v6 = self.bind(&socket_factory, SocketAddr::V6(UNSPECIFIED_V6_SOCKET));
    }

    fn bind(
        &mut self,
        socket_factory: &Arc<dyn SocketFactory<UdpSocket>>,
        addr: SocketAddr,
    ) -> Option<LocalUdpSocket> {
        match LocalUdpSocket::new(socket_factory.clone(), addr) {
            Ok(socket) => Some(socket),
            Err(e) => {
                // A family we cannot bind is survivable on its own - the other one carries the
                // session - so the event-loop decides what a failure means instead of us.
                self.bind_errors.push_back(
                    anyhow::Error::new(e).context(format!("Failed to bind UDP socket on {addr}")),
                );

                None
            }
        }
    }

    pub fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        if let Some(socket) = self.socket_v4.as_mut() {
            ready!(socket.poll_send_ready(cx))?;
        }

        if let Some(socket) = self.socket_v6.as_mut() {
            ready!(socket.poll_send_ready(cx))?;
        }

        Poll::Ready(Ok(()))
    }

    pub fn send(&mut self, datagram: DatagramOut) -> Result<()> {
        let socket = match datagram.dst {
            SocketAddr::V4(dst) => self.socket_v4.as_mut().ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("failed send packet to {dst}: no IPv4 socket"),
                )
            })?,
            SocketAddr::V6(dst) => self.socket_v6.as_mut().ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("failed send packet to {dst}: no IPv6 socket"),
                )
            })?,
        };
        socket.send(datagram);

        Ok(())
    }

    /// Polls for batches of received UDP datagrams, at most [`UDP_RECV_BATCH_LIMIT`] per socket.
    pub fn poll_recv_from(&mut self, cx: &mut Context<'_>) -> Poll<Buffer<VecBuf<DatagramBatch>>> {
        let mut batches = batches_pool_pull();

        if let Some(socket) = self.socket_v4.as_mut() {
            socket.poll_recv_from(cx, &mut batches);
        }

        if let Some(socket) = self.socket_v6.as_mut() {
            socket.poll_recv_from(cx, &mut batches);
        }

        if batches.is_empty() {
            return Poll::Pending;
        }

        Poll::Ready(batches)
    }

    pub fn poll_error(&mut self, cx: &mut Context<'_>) -> Poll<anyhow::Error> {
        if let Some(error) = self.bind_errors.pop_front() {
            return Poll::Ready(error);
        }

        if let Some(socket) = self.socket_v4.as_mut()
            && let Poll::Ready(e) = socket.poll_error(cx)
        {
            return Poll::Ready(e);
        }

        if let Some(socket) = self.socket_v6.as_mut()
            && let Poll::Ready(e) = socket.poll_error(cx)
        {
            return Poll::Ready(e);
        }

        Poll::Pending
    }
}

struct LocalUdpSocket {
    socket: Rc<PerfUdpSocket>,
    preferred_addr: SocketAddr,
    outbound: VecDeque<DatagramOut>,
    send_future: Option<futures::future::LocalBoxFuture<'static, Result<()>>>,
    errors: VecDeque<anyhow::Error>,
    io_error_counter: opentelemetry::metrics::Counter<u64>,
}

impl LocalUdpSocket {
    fn new(sf: Arc<dyn SocketFactory<UdpSocket>>, preferred_addr: SocketAddr) -> io::Result<Self> {
        let mut socket = listen(
            sf,
            &[preferred_addr, SocketAddr::new(preferred_addr.ip(), 0)],
        )?;
        let send_buffer_size = read_end_var_usize("FIREZONE_UDP_SEND_BUFFER_SIZE")
            .inspect_err(|e| tracing::debug!("Failed to read `FIREZONE_UDP_SEND_BUFFER_SIZE`: {e}"))
            .unwrap_or_default()
            .unwrap_or(socket_factory::SEND_BUFFER_SIZE);
        let recv_buffer_size = read_end_var_usize("FIREZONE_UDP_RECV_BUFFER_SIZE")
            .inspect_err(|e| tracing::debug!("Failed to read `FIREZONE_UDP_RECV_BUFFER_SIZE`: {e}"))
            .unwrap_or_default()
            .unwrap_or(socket_factory::RECV_BUFFER_SIZE);
        socket.set_buffer_sizes(send_buffer_size, recv_buffer_size);
        Ok(Self {
            socket: Rc::new(socket),
            preferred_addr,
            outbound: VecDeque::new(),
            send_future: None,
            errors: VecDeque::new(),
            io_error_counter: otel_instruments::network_errors(),
        })
    }

    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        loop {
            if let Some(future) = &mut self.send_future {
                let result = ready!(future.poll_unpin(cx));
                self.send_future = None;
                if let Err(error) = result {
                    self.record_error(&error, otel::attr::network_io_direction_transmit());
                    return Poll::Ready(Err(error));
                }
            }
            let Some(datagram) = self.outbound.pop_front() else {
                return Poll::Ready(Ok(()));
            };
            let socket = self.socket.clone();
            self.send_future = Some(async move { socket.send(datagram).await }.boxed_local());
        }
    }

    fn send(&mut self, datagram: DatagramOut) {
        self.outbound.push_back(datagram);
    }

    fn poll_recv_from(&mut self, cx: &mut Context<'_>, batches: &mut Vec<DatagramBatch>) {
        for _ in 0..UDP_RECV_BATCH_LIMIT {
            match self.socket.poll_recv_from(cx) {
                Poll::Ready(Ok(batch)) => batches.push(batch),
                Poll::Ready(Err(error)) => {
                    self.record_error(&error, otel::attr::network_io_direction_receive());
                    self.errors.push_back(error);
                    cx.waker().wake_by_ref();
                    break;
                }
                Poll::Pending => break,
            }
        }
    }

    fn poll_error(&mut self, _cx: &mut Context<'_>) -> Poll<anyhow::Error> {
        match self.errors.pop_front() {
            Some(error) => Poll::Ready(error),
            None => Poll::Pending,
        }
    }

    fn record_error(&self, error: &anyhow::Error, direction: opentelemetry::KeyValue) {
        use anyhow::ErrorExt as _;
        if let Some(error) = error.any_downcast_ref::<io::Error>() {
            self.io_error_counter.add(
                1,
                &[
                    direction,
                    otel::attr::network_type_for_addr(self.preferred_addr),
                    otel::attr::io_error_type(error),
                    otel::attr::io_error_code(error),
                ],
            );
        }
    }
}

fn listen(
    sf: Arc<dyn SocketFactory<UdpSocket>>,
    addresses: &[SocketAddr],
) -> io::Result<PerfUdpSocket> {
    let mut last_err = None;

    for addr in addresses {
        match sf.bind(*addr).and_then(|s| s.into_perf()) {
            Ok(s) => return Ok(s),
            Err(e) => {
                tracing::debug!(%addr, "Failed to listen on UDP socket: {e}");

                last_err = Some(e);
            }
        };
    }

    Err(last_err.unwrap_or_else(|| io::Error::other("No addresses to listen on")))
}

fn read_end_var_usize(name: &str) -> Result<Option<usize>> {
    let var = match std::env::var(name) {
        Ok(var) => var,
        Err(VarError::NotPresent) => return Ok(None),
        Err(e @ VarError::NotUnicode(_)) => return Err(anyhow::Error::new(e)),
    };

    let var = var.parse().context("Failed to parse as usize")?;

    Ok(Some(var))
}
