use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
    time::Instant,
};

use itertools::Itertools as _;
use snownet::Transmit;
use socket_factory::{DatagramBatch, DatagramOut};
use tunnel::{ClientState, FakeTunnelEnds, ResolverQuery, Role, Tunnel};

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

        for ((is_ipv4, _), transmits) in &by_socket {
            let socket = if is_ipv4 {
                &self.ends.socket_v4
            } else {
                &self.ends.socket_v6
            };

            socket
                .receive(DatagramBatch::received(transmits.map(|transmit| {
                    DatagramOut {
                        src: transmit.src,
                        dst: transmit.dst,
                        segment_size: transmit.payload.len(),
                        packet: transmit.payload,
                        ecn: transmit.ecn,
                    }
                })))
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
        if self.alarm.is_some_and(|alarm| alarm <= now) {
            self.alarm = None;
            self.inner.handle_timeout(now);
        }

        let woken = Arc::new(Woken::default());
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

        if woken.0.load(Ordering::Relaxed) {
            return (None, true);
        }

        self.alarm = self.inner.next_timeout(now);

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
