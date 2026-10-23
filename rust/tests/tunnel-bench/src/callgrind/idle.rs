use std::collections::VecDeque;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use crate::fixture::{
    Client, Connectivity, GATEWAY_SOCKET, KEEPALIVE, Relay, Resource, Tunnel, client_index,
    client_socket, receive,
};
use bufferpool::Bytes;
use socket_factory::DatagramOut;
use tunnel::GatewayState;

use super::{EventLoop, seeded_rng};

/// How long a benchmark keeps the connections idle: whole keepalive periods, so that it covers
/// every phase of the connections' timers.
const DURATION: Duration = Duration::from_secs(5 * KEEPALIVE.as_secs());

/// How many datagrams one receive returns at most (`quinn_udp::BATCH_SIZE` on Linux).
const RECV_BATCH_SIZE: usize = 32;

/// Idle connections from Clients to a Gateway's event loop.
///
/// The Clients and the relay run on their sans-IO states, and datagrams pass between them and
/// the Gateway without delay. Simulated time jumps from one deadline to the next.
pub struct Idle {
    gateway: EventLoop<GatewayState>,
    clients: Vec<Client>,
    client_deadlines: Vec<Option<Instant>>,
    relay: Relay,
    now: Instant,
    /// Datagrams in flight, as source, destination and payload.
    in_flight: VecDeque<(SocketAddr, SocketAddr, Vec<u8>)>,
}

impl Idle {
    pub fn new(connectivity: Connectivity, clients: usize) -> Self {
        seeded_rng::reset();

        let Tunnel {
            mut clients,
            gateway,
            relay,
            now,
        } = Tunnel::established(clients, connectivity, Resource::Cidr, true);
        let client_deadlines = clients
            .iter_mut()
            .map(|client| client.state.poll_timeout())
            .collect();

        let mut idle = Self {
            gateway: EventLoop::new(gateway),
            clients,
            client_deadlines,
            relay,
            now,
            in_flight: VecDeque::new(),
        };
        idle.wake_gateway();

        idle
    }

    /// Lets [`DURATION`] of simulated time pass.
    pub fn run(&mut self) {
        let end = self.now + DURATION;

        while let Some(next) = self
            .client_deadlines
            .iter()
            .chain([&self.gateway.deadline()])
            .flatten()
            .min()
            .copied()
            .filter(|next| *next <= end)
        {
            self.now = self.now.max(next);
            let now = self.now;

            if self.gateway.deadline().is_some_and(|t| t <= now) {
                self.wake_gateway();
            }
            for index in 0..self.clients.len() {
                if self.client_deadlines[index].is_some_and(|t| t <= now) {
                    self.clients[index].state.handle_timeout(now);
                    self.flush_client(index);
                }
            }
            self.deliver();
        }
        self.now = end;
    }

    /// Delivers the datagrams in flight and those sent in turn, until there are none.
    fn deliver(&mut self) {
        let mut to_gateway = Vec::new();

        while !self.in_flight.is_empty() {
            while let Some((from, to, payload)) = self.in_flight.pop_front() {
                if self.relay.serves(to) {
                    let datagrams = self.relay.handle(from, to, &payload, self.now);
                    self.in_flight.extend(datagrams);

                    continue;
                }

                if to == *GATEWAY_SOCKET {
                    to_gateway.push((from, payload));

                    continue;
                }

                if let Some(index) = client_index(to).filter(|index| *index < self.clients.len()) {
                    receive(&mut self.clients[index].state, to, from, &payload, self.now);
                    self.flush_client(index);
                }
            }

            let mut batches = to_gateway
                .chunks(RECV_BATCH_SIZE)
                .map(|datagrams| {
                    super::received(
                        *GATEWAY_SOCKET,
                        datagrams.iter().map(|(from, payload)| {
                            let mut buffer = Bytes::fitting(payload.len());
                            buffer.extend_from_slice(payload);

                            (*from, buffer, payload.len())
                        }),
                    )
                })
                .collect::<VecDeque<_>>();
            to_gateway.clear();

            if batches.is_empty() {
                continue;
            }
            while let Some(batch) = batches.pop_front() {
                if let Err(batch) = self.gateway.receive(batch) {
                    batches.push_front(batch);
                    self.wake_gateway();
                }
            }
            self.wake_gateway();
        }
    }

    /// Runs the Gateway's event loop and puts what it sent in flight.
    fn wake_gateway(&mut self) {
        self.gateway.run(self.now);

        let mut sent = Vec::<DatagramOut>::new();
        self.gateway.take_sent(&mut sent);
        for datagram in sent {
            for segment in datagram.packet.chunks(datagram.segment_size) {
                self.in_flight
                    .push_back((*GATEWAY_SOCKET, datagram.dst, segment.to_vec()));
            }
        }
    }

    fn flush_client(&mut self, index: usize) {
        let client = &mut self.clients[index].state;

        for _ in std::iter::from_fn(|| client.poll_event()) {}
        for _ in std::iter::from_fn(|| client.poll_packets()) {}
        while let Some(transmit) = client.poll_transmit() {
            self.in_flight.push_back((
                client_socket(index),
                transmit.dst,
                transmit.payload.to_vec(),
            ));
        }
        self.client_deadlines[index] = client.poll_timeout();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connections_stay_up() {
        let mut idle = Idle::new(Connectivity::Ice, 3);
        idle.run();

        let now = idle.now;
        for client in &mut idle.clients {
            assert!(
                client
                    .state
                    .handle_tun_input(&mut client.request(), now)
                    .unwrap()
                    .is_some()
            );
        }
    }
}
