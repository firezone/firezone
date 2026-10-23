//! A [`ClientTunnel`](tunnel::ClientTunnel) / [`GatewayTunnel`](tunnel::GatewayTunnel) event loop
//! that Callgrind can count the instructions of.
//!
//! The event loop runs on the calling thread and on simulated time: its crypto jobs run inline,
//! the benchmark stands in for its UDP socket and TUN device, and time only moves when the
//! benchmark moves it, to the deadline the event loop asked for. Only [`EventLoop::run`] is
//! counted.

#![allow(clippy::unwrap_used)]

mod callgrind;
mod idle;
mod packets;
mod seeded_rng;

use std::future::Future as _;
use std::net::SocketAddr;
use std::pin::pin;
use std::task::{Context, Poll, Waker};
use std::time::Instant;

use bufferpool::Bytes;
use socket_factory::{DatagramBatch, DatagramOut};
use tun::{InboundTx, OutboundRx, PacketBatch};
use tunnel::{ClientState, GatewayState, SocketThreadEnds, Tunnel, TunnelError};

pub use idle::Idle;
pub use packets::{Direction, Packets};
pub use tunnel_fixture::{Connectivity, Resource};

/// Runs `f`, counting only what it runs in [`EventLoop::run`].
///
/// Discards what was counted before, such as AEAD calls during set-up that
/// `--toggle-collect` counted.
pub fn measure<T>(f: impl FnOnce() -> T) -> T {
    callgrind::zero_stats();
    callgrind::toggle_collect();
    let result = f();
    callgrind::toggle_collect();

    result
}

/// How many batches the TUN device's outbound channel holds, as many as a real one's.
const TUN_CAPACITY: usize = 100;

/// A tunnel's event loop, driven the way the Client and the Gateway drive theirs.
pub struct EventLoop<R> {
    tunnel: Tunnel<R>,
    socket: SocketThreadEnds,
    /// What the TUN device reads.
    tun_reads: InboundTx,
    /// What the event loop writes to the TUN device.
    tun_writes: OutboundRx,
    /// The deadline the event loop asked to be woken at.
    alarm: Option<Instant>,
    /// Provides the timers of the tunnel's I/O, on a clock that stands still.
    runtime: tokio::runtime::Runtime,
}

impl<R: Role> EventLoop<R> {
    pub fn new(state: R) -> Self {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .start_paused(true)
            .build()
            .unwrap();
        let _guard = runtime.enter();

        let (mut tunnel, socket) = state.inline();
        let (tun, tun_reads, tun_writes) = tun::fake(TUN_CAPACITY);
        tunnel.set_tun(tun);

        drop(_guard);

        Self {
            tunnel,
            socket,
            tun_reads,
            tun_writes,
            alarm: None,
            runtime,
        }
    }

    /// Wakes the event loop at `now` and polls it until it waits for input or a later deadline.
    ///
    /// Like the Client's and the Gateway's event loops, it handles a deadline that has passed
    /// before anything else, and asks for the next deadline only once the tunnel is pending.
    pub fn run(&mut self, now: Instant) {
        let _guard = self.runtime.enter();
        let mut cx = Context::from_waker(Waker::noop());

        callgrind::toggle_collect();
        loop {
            if self.alarm.is_some_and(|alarm| alarm <= now) {
                self.alarm = None;
                self.tunnel.state_mut().handle_timeout(now);
            }

            while let Poll::Ready(result) = R::poll(&mut self.tunnel, &mut cx, now) {
                if let Err(mut errors) = result {
                    for _ in errors.drain() {}
                }
            }

            self.alarm = R::next_timeout(&mut self.tunnel, now);

            if !self.alarm.is_some_and(|alarm| alarm <= now) {
                break;
            }
        }
        callgrind::toggle_collect();
    }

    /// The deadline the event loop asked to be woken at.
    pub fn deadline(&self) -> Option<Instant> {
        self.alarm
    }

    /// Hands `batch` to the event loop as if the TUN device had read it.
    pub fn read_from_tun(&self, batch: PacketBatch) {
        let send = pin!(self.tun_reads.send(batch));

        assert!(
            send.poll(&mut Context::from_waker(Waker::noop()))
                .is_ready(),
            "TUN channel should have room"
        );
    }

    /// Returns how many packets the event loop wrote to the TUN device, dropping them.
    pub fn written_to_tun(&mut self) -> usize {
        let mut cx = Context::from_waker(Waker::noop());
        let mut packets = 0;

        while let Poll::Ready(Some(batch)) = pin!(self.tun_writes.recv()).poll(&mut cx) {
            packets += batch.len();
        }

        packets
    }

    /// Hands `batch` to the event loop as if its socket had received it, or returns it if the
    /// socket's channel is full.
    pub fn receive(&self, batch: DatagramBatch) -> Result<(), DatagramBatch> {
        self.socket.receive(batch)
    }

    /// Appends the datagrams the event loop sent to `sent`.
    pub fn take_sent(&mut self, sent: &mut Vec<DatagramOut>) {
        self.socket.take_sent(sent);
    }
}

/// The calls that differ between a [`ClientTunnel`](tunnel::ClientTunnel) and a
/// [`GatewayTunnel`](tunnel::GatewayTunnel).
pub trait Role: Sized {
    fn inline(self) -> (Tunnel<Self>, SocketThreadEnds);
    fn poll(
        tunnel: &mut Tunnel<Self>,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> Poll<Result<(), TunnelError>>;
    fn next_timeout(tunnel: &mut Tunnel<Self>, now: Instant) -> Option<Instant>;
    fn handle_timeout(&mut self, now: Instant);
}

impl Role for ClientState {
    fn inline(self) -> (Tunnel<Self>, SocketThreadEnds) {
        Tunnel::<Self>::inline(self)
    }

    fn poll(
        tunnel: &mut Tunnel<Self>,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> Poll<Result<(), TunnelError>> {
        tunnel.poll_next_event(cx, now).map_ok(drop)
    }

    fn next_timeout(tunnel: &mut Tunnel<Self>, now: Instant) -> Option<Instant> {
        tunnel.next_timeout(now)
    }

    fn handle_timeout(&mut self, now: Instant) {
        ClientState::handle_timeout(self, now);
    }
}

impl Role for GatewayState {
    fn inline(self) -> (Tunnel<Self>, SocketThreadEnds) {
        Tunnel::<Self>::inline(self)
    }

    fn poll(
        tunnel: &mut Tunnel<Self>,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> Poll<Result<(), TunnelError>> {
        tunnel.poll_next_event(cx, now).map_ok(drop)
    }

    fn next_timeout(tunnel: &mut Tunnel<Self>, now: Instant) -> Option<Instant> {
        tunnel.next_timeout(now)
    }

    fn handle_timeout(&mut self, now: Instant) {
        GatewayState::handle_timeout(self, now);
    }
}

/// Creates a batch as if a socket bound to `local` had received `datagrams` in one syscall.
///
/// Each datagram is given by its source, its buffer and the size of the segments coalesced into
/// it.
fn received(
    local: SocketAddr,
    datagrams: impl IntoIterator<Item = (SocketAddr, Bytes, usize)>,
) -> DatagramBatch {
    let (buffers, metas): (Vec<_>, Vec<_>) = datagrams
        .into_iter()
        .map(|(from, buffer, stride)| {
            let mut meta = quinn_udp::RecvMeta::default();
            meta.addr = from;
            meta.len = buffer.len();
            meta.stride = stride;
            meta.dst_ip = Some(local.ip());

            (buffer, meta)
        })
        .unzip();
    let len = buffers.len();

    DatagramBatch::new(buffers, metas, local.port(), len)
}
