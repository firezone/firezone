//! A [`ClientTunnel`](tunnel::ClientTunnel) / [`GatewayTunnel`](tunnel::GatewayTunnel) event loop
//! that Callgrind can count the instructions of.
//!
//! The event loop runs on the calling thread and on simulated time: its crypto jobs run inline,
//! the benchmark stands in for its UDP socket and TUN device, and time only moves when the
//! benchmark moves it, to the deadline the event loop asked for. Only [`EventLoop::run`] is
//! counted.

#![allow(clippy::unwrap_used)]

mod idle;
mod packets;

use std::future::Future as _;
use std::pin::pin;
use std::task::{Context, Poll, Waker};
use std::time::Instant;

use snownet::Transmit;
use socket_factory::DatagramBatch;
use tun::PacketBatch;
use tunnel::{FakeTunnelEnds, Role, Tunnel};

use crate::callgrind;

pub use idle::Idle;
pub use packets::{Direction, Packets};

/// A tunnel's event loop, driven the way the Client and the Gateway drive theirs.
pub struct EventLoop<R> {
    tunnel: Tunnel<R>,
    /// The fake tunnel's TUN device, sockets and resolver; every address is IPv4.
    ends: FakeTunnelEnds,
    /// The deadline the event loop asked to be woken at.
    alarm: Option<Instant>,
}

impl<R: Role> EventLoop<R> {
    pub fn new(state: R) -> Self {
        let (tunnel, ends) = Tunnel::fake(state);

        Self {
            tunnel,
            ends,
            alarm: None,
        }
    }

    /// Wakes the event loop at `now` and polls it until it waits for input or a later deadline.
    ///
    /// Like the Client's and the Gateway's event loops, it handles a deadline that has passed
    /// before anything else, and asks for the next deadline only once the tunnel is pending.
    pub fn run(&mut self, now: Instant) {
        let mut cx = Context::from_waker(Waker::noop());

        callgrind::count(|| {
            loop {
                if self.alarm.is_some_and(|alarm| alarm <= now) {
                    self.tunnel.handle_timeout(now);
                }

                while let Poll::Ready(result) = self.tunnel.poll_next_event(&mut cx, now) {
                    if let Err(mut errors) = result {
                        for _ in errors.drain() {}
                    }
                }

                self.alarm = self.tunnel.next_timeout(now);

                if !self.alarm.is_some_and(|alarm| alarm <= now) {
                    break;
                }
            }
        });
    }

    /// The deadline the event loop asked to be woken at.
    pub fn deadline(&self) -> Option<Instant> {
        self.alarm
    }

    /// Hands `batch` to the event loop as if the TUN device had read it.
    pub fn read_from_tun(&self, batch: PacketBatch) {
        let send = pin!(self.ends.tun_inbound.send(batch));

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

        while let Poll::Ready(Some(batch)) = pin!(self.ends.tun_outbound.recv()).poll(&mut cx) {
            packets += batch.len();
        }

        packets
    }

    /// Hands `batch` to the event loop as if its socket had received it, or returns it if the
    /// socket's channel is full.
    pub fn receive(&self, batch: DatagramBatch) -> Result<(), DatagramBatch> {
        self.ends.socket_v4.receive(batch)
    }

    /// Takes the datagrams the event loop sent, split into the segments that go on the wire.
    pub fn take_sent(&mut self) -> Vec<Transmit> {
        self.ends.socket_v4.take_sent()
    }
}
