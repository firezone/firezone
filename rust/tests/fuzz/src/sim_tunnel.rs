use std::{
    collections::VecDeque,
    net::SocketAddr,
    task::{Context, Poll, Waker},
    time::Instant,
};

use ip_packet::{Ecn, IpPacket};
use snownet::Transmit;
use socket_factory::{DatagramBatch, DatagramOut};
use tun::{InboundTx, OutboundRx, PacketBatch};
use tunnel::{
    ClientEvent, ClientState, FakeTunnelEnds, GatewayEvent, GatewayState, ResolverQuery, Tunnel,
    TunnelError, dns,
};

/// How many batches the TUN device's outbound channel holds.
const TUN_CAPACITY: usize = 100;

/// How many datagrams a socket receives at once.
const RECV_BATCH_SIZE: usize = 32;

/// A tunnel and the OS around it: its TUN device and its sockets.
///
pub(crate) struct SimTunnel<R> {
    tunnel: Tunnel<R>,
    ends: FakeTunnelEnds,
    tun_reads: InboundTx,
    tun_writes: OutboundRx,
    /// The deadline the tunnel asked to be woken at.
    alarm: Option<Instant>,

    /// Packets the TUN device has yet to read.
    unread: VecDeque<IpPacket>,
    /// Datagrams the sockets have yet to receive.
    unreceived: VecDeque<Transmit>,
    /// Datagrams the tunnel sent.
    sent: VecDeque<Transmit>,
    /// Packets the tunnel wrote to the TUN device.
    written: VecDeque<IpPacket>,
}

impl<R: Role> SimTunnel<R> {
    pub(crate) fn new(state: R) -> Self {
        let (mut tunnel, ends) = Tunnel::fake(state);
        let (tun, tun_reads, tun_writes) = tun::fake(TUN_CAPACITY);
        tunnel.set_tun(tun);

        Self {
            tunnel,
            ends,
            tun_reads,
            tun_writes,
            alarm: None,
            unread: VecDeque::new(),
            unreceived: VecDeque::new(),
            sent: VecDeque::new(),
            written: VecDeque::new(),
        }
    }

    pub(crate) fn state(&self) -> &R {
        self.tunnel.state()
    }

    pub(crate) fn state_mut(&mut self) -> &mut R {
        self.tunnel.state_mut()
    }

    pub(crate) fn tunnel_mut(&mut self) -> &mut Tunnel<R> {
        &mut self.tunnel
    }

    /// Queues `packet` for the TUN device to read.
    pub(crate) fn read_from_tun(&mut self, packet: IpPacket) {
        self.unread.push_back(packet);
    }

    /// Queues `transmit` for the sockets to receive on `transmit.dst`.
    pub(crate) fn receive(&mut self, transmit: Transmit) {
        self.unreceived.push_back(transmit);
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<Transmit> {
        self.sent.pop_front()
    }

    pub(crate) fn poll_written(&mut self) -> Option<IpPacket> {
        self.written.pop_front()
    }

    /// Takes the next recursive DNS query the tunnel sent, ignoring its resolver configuration.
    pub(crate) fn poll_dns_query(&mut self) -> Option<ResolverQuery> {
        while self.ends.dns.try_recv_control().is_some() {}

        self.ends.dns.try_recv_query()
    }

    pub(crate) fn respond(&mut self, response: dns::RecursiveResponse) {
        if self.ends.dns.respond(response).is_err() {
            tracing::debug!("Resolver channel is full; dropping DNS response");
        }
    }

    /// The deadline the tunnel asked to be woken at when it last went idle.
    pub(crate) fn deadline(&self) -> Option<Instant> {
        self.alarm
    }

    /// Runs the tunnel until it emits an event or waits for input or a later deadline.
    ///
    /// Handles a deadline that has passed before anything else, and asks for the next deadline
    /// only once the tunnel is pending.
    pub(crate) fn poll_event(&mut self, now: Instant) -> Option<R::Event> {
        let mut cx = Context::from_waker(Waker::noop());

        loop {
            let fed = self.feed();

            if self.alarm.is_some_and(|alarm| alarm <= now) {
                self.alarm = None;
                self.tunnel.state_mut().handle_timeout(now);
            }

            let poll = R::poll(&mut self.tunnel, &mut cx, now);
            let drained = self.drain();

            match poll {
                Poll::Ready(Ok(event)) => return Some(event),
                Poll::Ready(Err(mut errors)) => {
                    for e in errors.drain() {
                        tracing::warn!("{e:#}");
                    }

                    continue;
                }
                Poll::Pending => {}
            }

            if fed || drained {
                continue;
            }

            self.alarm = R::next_timeout(&mut self.tunnel, now);

            if !self.alarm.is_some_and(|alarm| alarm <= now) {
                return None;
            }
        }
    }

    /// Hands the queued packets and datagrams to the tunnel, as far as its channels have room.
    fn feed(&mut self) -> bool {
        let mut fed = false;

        while let Some(first) = self.unread.pop_front() {
            let mut batch = PacketBatch::new(first);
            while let Some(packet) = self.unread.pop_front() {
                if let Err(packet) = batch.try_push(packet) {
                    self.unread.push_front(packet);
                    break;
                }
            }

            if let Err(e) = self.tun_reads.try_send(batch) {
                let mut batch = e.into_inner();
                for packet in batch.drain().collect::<Vec<_>>().into_iter().rev() {
                    self.unread.push_front(packet);
                }
                break;
            }

            fed = true;
        }

        while let Some(first) = self.unreceived.front() {
            let socket = match first.dst {
                SocketAddr::V4(_) => &self.ends.socket_v4,
                SocketAddr::V6(_) => &self.ends.socket_v6,
            };
            let local = first.dst;
            let len = self
                .unreceived
                .iter()
                .take(RECV_BATCH_SIZE)
                .take_while(|transmit| same_socket(transmit.dst, local))
                .count();
            let datagrams = self.unreceived.drain(..len).collect::<Vec<_>>();

            if socket.receive(received(local.port(), &datagrams)).is_err() {
                for transmit in datagrams.into_iter().rev() {
                    self.unreceived.push_front(transmit);
                }
                break;
            }

            fed = true;
        }

        fed
    }

    /// Takes what the tunnel sent and wrote to the TUN device out of their channels.
    fn drain(&mut self) -> bool {
        let num_sent = self.sent.len();
        let num_written = self.written.len();

        let mut datagrams = Vec::new();
        self.ends.socket_v4.take_sent(&mut datagrams);
        self.ends.socket_v6.take_sent(&mut datagrams);
        self.sent.extend(datagrams.into_iter().flat_map(segments));

        while let Ok(mut batch) = self.tun_writes.try_recv() {
            self.written.extend(batch.drain());
        }

        self.sent.len() != num_sent || self.written.len() != num_written
    }
}

impl SimTunnel<ClientState> {
    /// Shuts the tunnel down, returning the datagrams it sent on the way out.
    pub(crate) fn shut_down(mut self, now: Instant) -> impl Iterator<Item = Transmit> {
        self.tunnel.state_mut().shut_down(now);
        while self.poll_event(now).is_some() {}

        self.sent.into_iter()
    }
}

/// Whether a datagram to `dst` is received by the same socket as one to `local`.
fn same_socket(dst: SocketAddr, local: SocketAddr) -> bool {
    dst.is_ipv4() == local.is_ipv4() && dst.port() == local.port()
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
