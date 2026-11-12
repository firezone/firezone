use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
    time::Instant,
};

use ip_packet::IpPacket;
use itertools::Itertools as _;
use snownet::Transmit;
use socket_factory::{DatagramBatch, DatagramOut};
use tun::PacketBatch;
use tunnel::{ClientState, FakeTunnelEnds, ResolverQuery, Role, Tunnel};

/// A tunnel and the OS around it: its TUN device and its sockets.
pub(crate) struct SimTunnel<R> {
    inner: Tunnel<R>,
    pub(crate) ends: FakeTunnelEnds,
    /// The packets the TUN device reads on the next poll.
    pending_tun_reads: Vec<IpPacket>,
    /// The deadline the tunnel asked to be woken at when it last went idle.
    pub(crate) alarm: Option<Instant>,
    /// Whether the last poll found nothing to do and nothing has touched the tunnel since.
    idle: bool,
    /// Set by any waker the tunnel was ever handed.
    woken_since_idle: Arc<AtomicBool>,
}

impl<R: Role> SimTunnel<R> {
    pub(crate) fn new(state: R) -> Self {
        let (tunnel, ends) = Tunnel::fake(state);

        Self {
            inner: tunnel,
            ends,
            pending_tun_reads: Vec::new(),
            alarm: None,
            idle: false,
            woken_since_idle: Arc::default(),
        }
    }

    pub(crate) fn inner(&self) -> &Tunnel<R> {
        &self.inner
    }

    pub(crate) fn inner_mut(&mut self) -> &mut Tunnel<R> {
        self.idle = false;

        &mut self.inner
    }

    /// Queues `packet` for the TUN device to read.
    pub(crate) fn read_from_tun(&mut self, packet: IpPacket) {
        self.pending_tun_reads.push(packet);
    }

    /// Hands `transmits` to the sockets they are addressed to, one batch per socket.
    pub(crate) fn receive(&mut self, transmits: Vec<Transmit>) {
        let by_socket = transmits
            .into_iter()
            .chunk_by(|transmit| (transmit.dst.is_ipv4(), transmit.dst.port()));

        for ((is_ipv4, _), transmits) in &by_socket {
            let socket = if is_ipv4 {
                &self.ends.socket_v4
            } else {
                &self.ends.socket_v6
            };

            let datagrams =
                transmits.fold(Vec::<Vec<Transmit>>::new(), |mut datagrams, transmit| {
                    match datagrams.last_mut() {
                        Some(segments) if gro_merges(segments, &transmit) => {
                            segments.push(transmit)
                        }
                        _ => datagrams.push(vec![transmit]),
                    }

                    datagrams
                });

            socket
                .receive(DatagramBatch::from_datagrams(
                    datagrams.into_iter().map(coalesce),
                ))
                .expect("socket channel has room");
        }
    }

    /// Takes what the tunnel sent out of the sockets' channels.
    pub(crate) fn take_sent(&mut self) -> Vec<Transmit> {
        let mut sent = self.ends.socket_v4.take_sent();
        sent.extend(self.ends.socket_v6.take_sent());

        sent
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
        self.flush_tun_reads();

        if self.alarm.is_some_and(|alarm| alarm <= now) {
            self.alarm = None;
            self.idle = false;
            self.inner.handle_timeout(now);
        }

        let woken_since_idle = self.woken_since_idle.swap(false, Ordering::Relaxed);
        if self.idle && !woken_since_idle {
            return (None, false);
        }
        self.idle = false;

        let woken = Arc::new(Woken {
            this_poll: AtomicBool::new(false),
            since_idle: self.woken_since_idle.clone(),
        });
        let waker = Waker::from(woken.clone());

        match self
            .inner
            .poll_next_event(&mut Context::from_waker(&waker), now)
        {
            Poll::Ready(Ok(event)) => return (Some(event), true),
            Poll::Ready(Err(mut errors)) => {
                for e in errors.drain() {
                    tracing::warn!("{e:#}");
                }

                return (None, true);
            }
            Poll::Pending => {}
        }

        if woken.this_poll.load(Ordering::Relaxed) {
            return (None, true);
        }

        self.idle = true;
        self.alarm = self.inner.next_timeout(now);

        (None, self.alarm.is_some_and(|alarm| alarm <= now))
    }

    /// Hands the queued packets to the TUN device's channel, as many per read as a real device
    /// returns.
    fn flush_tun_reads(&mut self) {
        let mut batches = Vec::<PacketBatch>::new();

        for packet in self.pending_tun_reads.drain(..) {
            let packet = match batches.last_mut() {
                Some(batch) => match batch.try_push(packet) {
                    Ok(()) => continue,
                    Err(packet) => packet,
                },
                _ => packet,
            };

            batches.push(PacketBatch::new(packet));
        }

        for batch in batches {
            self.ends
                .tun_inbound
                .try_send(batch)
                .expect("TUN channel has room");
        }
    }
}

impl SimTunnel<ClientState> {
    /// Shuts the tunnel down, returning the datagrams it sent on the way out.
    pub(crate) fn shut_down(mut self, now: Instant) -> Vec<Transmit> {
        self.inner_mut().state_mut().shut_down(now);
        while self.poll_event(now).1 {}

        self.take_sent()
    }
}

/// Whether Linux GRO appends `next` to the datagram made of `segments`.
fn gro_merges(segments: &[Transmit], next: &Transmit) -> bool {
    let (Some(first), Some(last)) = (segments.first(), segments.last()) else {
        return false;
    };
    let segment_size = first.payload.len();
    let len = segments
        .iter()
        .map(|segment| segment.payload.len())
        .sum::<usize>();

    first.src == next.src
        && first.dst == next.dst
        && first.ecn == next.ecn
        && last.payload.len() == segment_size
        && (1..=segment_size).contains(&next.payload.len())
        && len + next.payload.len() <= DatagramOut::max_len(next.dst, segment_size)
}

/// Builds the datagram a socket receives for `segments`, coalesced as by GRO.
fn coalesce(segments: Vec<Transmit>) -> DatagramOut {
    let first = &segments[0];
    let len = segments.iter().map(|segment| segment.payload.len()).sum();
    let mut packet = bufferpool::Bytes::fitting(len);
    for segment in &segments {
        packet.extend_from_slice(&segment.payload);
    }

    DatagramOut {
        src: first.src,
        dst: first.dst,
        segment_size: first.payload.len(),
        packet,
        ecn: first.ecn,
    }
}

/// Records whether the tunnel asked to be polled again.
struct Woken {
    this_poll: AtomicBool,
    since_idle: Arc<AtomicBool>,
}

impl Wake for Woken {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.this_poll.store(true, Ordering::Relaxed);
        self.since_idle.store(true, Ordering::Relaxed);
    }
}
