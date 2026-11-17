use std::collections::VecDeque;
use std::time::Instant;

use crate::callgrind;
use crate::fixture::{AnyHost, Host, Resource, connect, tun_batches};
use socket_factory::{DatagramBatch, DatagramOut};
use tun::PacketBatch;

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
    host: AnyHost,
    inputs: VecDeque<Input>,
    now: Instant,
}

enum Input {
    Tun(PacketBatch),
    Network(DatagramBatch),
}

impl Packets {
    /// Connects a Client to a Gateway with flow logs on and lets the event loop of `direction`'s
    /// side handle [`WARM_UP`] packets.
    pub fn new(direction: Direction, resource: Resource) -> Self {
        let (client, gateway, now) = connect(resource);
        let (local, mut peer) = match direction {
            Direction::ClientOutbound | Direction::ClientInbound => (client, gateway),
            Direction::GatewayInbound | Direction::GatewayOutbound => (gateway, client),
        };
        let mut inputs = |count| -> VecDeque<Input> {
            match direction {
                Direction::ClientOutbound | Direction::GatewayOutbound => {
                    tun_batches(&local.reads, count)
                        .into_iter()
                        .map(Input::Tun)
                        .collect()
                }
                Direction::GatewayInbound | Direction::ClientInbound => peer
                    .encrypt(count, local.socket, now)
                    .into_iter()
                    .map(|datagram| {
                        Input::Network(DatagramBatch::from_datagrams([DatagramOut {
                            src: Some(peer.socket),
                            ..datagram
                        }]))
                    })
                    .collect(),
            }
        };
        let warm_up = inputs(WARM_UP);
        let inputs = inputs(PACKETS);

        let host = local.host;
        let mut packets = Self {
            host,
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
        match &mut self.host {
            AnyHost::Client(host) => send(host, &mut self.inputs, count, self.now),
            AnyHost::Gateway(host) => send(host, &mut self.inputs, count, self.now),
        }
    }
}

fn send<R: tunnel::Role>(
    host: &mut Host<R>,
    inputs: &mut VecDeque<Input>,
    count: usize,
    now: Instant,
) {
    let mut delivered = 0;

    while delivered < count {
        let pending = inputs.len();
        while let Some(input) = inputs.pop_front() {
            match input {
                Input::Tun(batch) => host.read_from_tun(batch),
                Input::Network(batch) => {
                    if let Err(batch) = host.receive(batch) {
                        inputs.push_front(Input::Network(batch));
                        break;
                    }
                }
            }
        }

        callgrind::count(|| host.run(now));

        let before = delivered;
        delivered += host.written_to_tun().len();
        delivered += host.take_sent().len();

        assert!(
            delivered > before || inputs.len() < pending,
            "{} packets got lost",
            count - delivered
        );
    }
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
