use std::collections::VecDeque;
use std::time::Instant;

use ip_packet::IpPacket;
use socket_factory::{DatagramBatch, DatagramOut};
use tun::PacketBatch;
use tunnel::{ClientState, GatewayState};
use tunnel_fixture::{Resource, State, connect};

use crate::{EventLoop, seeded_rng};

/// How many packets a benchmark sends through the event loop.
pub const PACKETS: usize = 1024;

/// How many packets the event loop handles before a benchmark, so that it starts with its pools
/// and tables grown.
const WARM_UP: usize = 256;

#[derive(Debug, Clone, Copy)]
pub enum Direction {
    ClientOutbound,
    GatewayInbound,
    GatewayOutbound,
    ClientInbound,
}

/// Packets for one side of an established connection to handle, as the TUN device reads them or
/// the socket receives them from the other side.
pub struct Packets {
    event_loop: AnyEventLoop,
    inputs: VecDeque<Input>,
    now: Instant,
}

enum AnyEventLoop {
    Client(EventLoop<ClientState>),
    Gateway(EventLoop<GatewayState>),
}

enum Input {
    Tun(PacketBatch),
    Network(DatagramBatch),
}

impl Packets {
    /// Connects a Client to a Gateway with flow logs on and lets the event loop of `direction`'s
    /// side handle [`WARM_UP`] packets.
    pub fn new(direction: Direction, resource: Resource) -> Self {
        seeded_rng::reset();

        let (client, gateway, now) = connect(resource, true);
        let (local, mut peer) = match direction {
            Direction::ClientOutbound | Direction::ClientInbound => (client, gateway),
            Direction::GatewayInbound | Direction::GatewayOutbound => (gateway, client),
        };
        let mut inputs = |count| match direction {
            Direction::ClientOutbound | Direction::GatewayOutbound => tun_batches(&local, count),
            Direction::GatewayInbound | Direction::ClientInbound => {
                received_batches(&local, &mut peer, count, now)
            }
        };
        let warm_up = inputs(WARM_UP);
        let inputs = inputs(PACKETS);

        let event_loop = match local.state {
            State::Client(state) => AnyEventLoop::Client(EventLoop::new(state)),
            State::Gateway(state) => AnyEventLoop::Gateway(EventLoop::new(state)),
        };
        let mut packets = Self {
            event_loop,
            inputs: warm_up,
            now,
        };
        packets.send(WARM_UP);
        packets.inputs = inputs;

        packets
    }

    /// Sends the [`PACKETS`] through the event loop.
    pub fn run(&mut self) {
        self.send(PACKETS);
    }

    /// Hands the inputs to the event loop as fast as it takes them, until `count` packets came
    /// out of it.
    fn send(&mut self, count: usize) {
        match &mut self.event_loop {
            AnyEventLoop::Client(event_loop) => send(event_loop, &mut self.inputs, count, self.now),
            AnyEventLoop::Gateway(event_loop) => {
                send(event_loop, &mut self.inputs, count, self.now)
            }
        }
    }
}

fn send<R: crate::Role>(
    event_loop: &mut EventLoop<R>,
    inputs: &mut VecDeque<Input>,
    count: usize,
    now: Instant,
) {
    let mut delivered = 0;
    let mut sent = Vec::<DatagramOut>::new();

    while delivered < count {
        let pending = inputs.len();
        while let Some(input) = inputs.pop_front() {
            match input {
                Input::Tun(batch) => event_loop.read_from_tun(batch),
                Input::Network(batch) => {
                    if let Err(batch) = event_loop.receive(batch) {
                        inputs.push_front(Input::Network(batch));
                        break;
                    }
                }
            }
        }

        event_loop.run(now);

        let before = delivered;
        delivered += event_loop.written_to_tun();
        event_loop.take_sent(&mut sent);
        delivered += sent
            .drain(..)
            .map(|datagram| datagram.packet.len().div_ceil(datagram.segment_size))
            .sum::<usize>();

        assert!(
            delivered > before || inputs.len() < pending,
            "{} packets got lost",
            count - delivered
        );
    }
}

/// Returns `count` copies of what `local` reads from its TUN device, in batches as full as the
/// TUN device's.
fn tun_batches(local: &tunnel_fixture::Side, count: usize) -> VecDeque<Input> {
    let packets = vec![local.reads.clone(); count];

    packets
        .chunks(tun::MAX_BATCH_SIZE)
        .map(|chunk| {
            let mut batch = PacketBatch::default();
            for packet in chunk {
                batch.try_push(IpPacket::clone(packet)).unwrap();
            }

            Input::Tun(batch)
        })
        .collect()
}

/// Returns `count` copies of what `peer` reads from its TUN device, encrypted for `local` and
/// coalesced like GRO does.
fn received_batches(
    local: &tunnel_fixture::Side,
    peer: &mut tunnel_fixture::Side,
    count: usize,
    now: Instant,
) -> VecDeque<Input> {
    peer.state
        .encapsulate(&peer.reads, count, now, local.socket)
        .into_iter()
        .map(|datagram| {
            Input::Network(crate::received(
                local.socket,
                [(peer.socket, datagram.packet, datagram.segment_size)],
            ))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packets_arrive() {
        for resource in [Resource::Cidr, Resource::Dns] {
            for direction in [
                Direction::ClientOutbound,
                Direction::GatewayInbound,
                Direction::GatewayOutbound,
                Direction::ClientInbound,
            ] {
                Packets::new(direction, resource).run();
            }
        }
    }
}
