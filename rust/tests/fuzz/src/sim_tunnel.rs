use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
    time::Instant,
};

use ip_packet::Ecn;
use itertools::Itertools as _;
use snownet::Transmit;
use socket_factory::{DatagramBatch, DatagramOut};
use tunnel::{
    ClientEvent, ClientState, FakeTunnelEnds, GatewayEvent, GatewayState, ResolverQuery, Tunnel,
    TunnelError,
};

/// A tunnel and the OS around it: its TUN device and its sockets.
pub(crate) struct SimTunnel<R> {
    pub(crate) inner: Tunnel<R>,
    pub(crate) ends: FakeTunnelEnds,
    /// The deadline the tunnel asked to be woken at when it last went idle.
    pub(crate) alarm: Option<Instant>,
}

impl<R: Role> SimTunnel<R> {
    pub(crate) fn new(state: R) -> Self {
        let (tunnel, ends) = Tunnel::fake(state);

        Self {
            inner: tunnel,
            ends,
            alarm: None,
        }
    }

    /// Hands `transmits` to the sockets they are addressed to, one batch per socket.
    pub(crate) fn receive(&mut self, transmits: Vec<Transmit>) {
        let by_socket = transmits
            .into_iter()
            .chunk_by(|transmit| (transmit.dst.is_ipv4(), transmit.dst.port()));

        for ((is_ipv4, port), datagrams) in &by_socket {
            let socket = if is_ipv4 {
                &self.ends.socket_v4
            } else {
                &self.ends.socket_v6
            };

            socket
                .receive(received(port, &datagrams.collect::<Vec<_>>()))
                .expect("socket channel has room");
        }
    }

    /// Takes what the tunnel sent out of the sockets' channels.
    pub(crate) fn take_sent(&mut self) -> Vec<Transmit> {
        let mut datagrams = Vec::new();
        self.ends.socket_v4.take_sent(&mut datagrams);
        self.ends.socket_v6.take_sent(&mut datagrams);

        datagrams.into_iter().flat_map(segments).collect()
    }

    /// Takes the next recursive DNS query the tunnel sent, ignoring its resolver configuration.
    pub(crate) fn poll_dns_query(&mut self) -> Option<ResolverQuery> {
        while self.ends.dns.try_recv_control().is_some() {}

        self.ends.dns.try_recv_query()
    }

    /// Handles a deadline that has passed and polls the tunnel once.
    ///
    /// Returns the event it emitted and whether it has more to do at `now`.
    pub(crate) fn poll_event(&mut self, now: Instant) -> (Option<R::Event>, bool) {
        if self.alarm.is_some_and(|alarm| alarm <= now) {
            self.alarm = None;
            self.inner.state_mut().handle_timeout(now);
        }

        let woken = Arc::new(Woken::default());
        let waker = Waker::from(woken.clone());

        match R::poll(&mut self.inner, &mut Context::from_waker(&waker), now) {
            Poll::Ready(Ok(event)) => return (Some(event), true),
            Poll::Ready(Err(mut errors)) => {
                for e in errors.drain() {
                    tracing::warn!("{e:#}");
                }

                return (None, true);
            }
            Poll::Pending => {}
        }

        if woken.0.load(Ordering::Relaxed) {
            return (None, true);
        }

        self.alarm = R::next_timeout(&mut self.inner, now);

        (None, self.alarm.is_some_and(|alarm| alarm <= now))
    }
}

impl SimTunnel<ClientState> {
    /// Shuts the tunnel down, returning the datagrams it sent on the way out.
    pub(crate) fn shut_down(mut self, now: Instant) -> Vec<Transmit> {
        self.inner.state_mut().shut_down(now);
        while self.poll_event(now).1 {}

        self.take_sent()
    }
}

/// Records whether the tunnel asked to be polled again.
#[derive(Default)]
struct Woken(AtomicBool);

impl Wake for Woken {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.store(true, Ordering::Relaxed);
    }
}

/// Creates a batch as if a socket bound to `port` had received `transmits` in one syscall.
fn received(port: u16, transmits: &[Transmit]) -> DatagramBatch {
    let (buffers, metas): (Vec<_>, Vec<_>) = transmits
        .iter()
        .map(|transmit| {
            let mut meta = quinn_udp::RecvMeta::default();
            meta.addr = transmit
                .src
                .expect("`src` should always be set in these tests");
            meta.len = transmit.payload.len();
            meta.stride = transmit.payload.len();
            meta.dst_ip = Some(transmit.dst.ip());
            meta.ecn = match transmit.ecn {
                Ecn::NonEct => None,
                Ecn::Ect1 => Some(quinn_udp::EcnCodepoint::Ect1),
                Ecn::Ect0 => Some(quinn_udp::EcnCodepoint::Ect0),
                Ecn::Ce => Some(quinn_udp::EcnCodepoint::Ce),
            };

            (transmit.payload.clone(), meta)
        })
        .unzip();
    let len = buffers.len();

    DatagramBatch::new(buffers, metas, port, len)
}

/// Splits a datagram sent with GSO into the datagrams it puts on the wire.
fn segments(datagram: DatagramOut) -> impl Iterator<Item = Transmit> {
    let segment_size = datagram.segment_size.max(1);

    datagram
        .packet
        .chunks(segment_size)
        .map(|segment| Transmit {
            src: datagram.src,
            dst: datagram.dst,
            payload: bufferpool::Bytes::copied_from(segment),
            ecn: datagram.ecn,
        })
        .collect::<Vec<_>>()
        .into_iter()
}

/// The calls that differ between a [`tunnel::ClientTunnel`] and a [`tunnel::GatewayTunnel`].
pub(crate) trait Role: Sized {
    type Event;

    fn poll(
        tunnel: &mut Tunnel<Self>,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> Poll<Result<Self::Event, TunnelError>>;
    fn next_timeout(tunnel: &mut Tunnel<Self>, now: Instant) -> Option<Instant>;
    fn handle_timeout(&mut self, now: Instant);
}

impl Role for ClientState {
    type Event = ClientEvent;

    fn poll(
        tunnel: &mut Tunnel<Self>,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> Poll<Result<Self::Event, TunnelError>> {
        tunnel.poll_next_event(cx, now)
    }

    fn next_timeout(tunnel: &mut Tunnel<Self>, now: Instant) -> Option<Instant> {
        tunnel.next_timeout(now)
    }

    fn handle_timeout(&mut self, now: Instant) {
        ClientState::handle_timeout(self, now);
    }
}

impl Role for GatewayState {
    type Event = GatewayEvent;

    fn poll(
        tunnel: &mut Tunnel<Self>,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> Poll<Result<Self::Event, TunnelError>> {
        tunnel.poll_next_event(cx, now)
    }

    fn next_timeout(tunnel: &mut Tunnel<Self>, now: Instant) -> Option<Instant> {
        tunnel.next_timeout(now)
    }

    fn handle_timeout(&mut self, now: Instant) {
        GatewayState::handle_timeout(self, now);
    }
}
