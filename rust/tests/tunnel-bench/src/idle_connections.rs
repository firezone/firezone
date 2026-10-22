//! The Gateway's work to keep idle connections to many Clients alive.
//!
//! Everything runs in-process on simulated time, which jumps from one timer to the next while
//! datagrams pass between the Gateway, the Clients and the relay without delay. Only the Gateway's
//! own calls count, made as its event loop makes them. One iteration is one connection-second.

#![allow(clippy::unwrap_used)]

use std::collections::{BTreeMap, VecDeque};
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use criterion::{Criterion, SamplingMode};
use tunnel::GatewayState;

use crate::fixture::{
    CONNECTIVITIES, GATEWAY_SOCKET, KEEPALIVE, Resource, Tunnel, client_index, client_socket,
    receive,
};
use crate::measure::Wall;

const GROUP: &str = "idle_connections";

const CLIENTS: usize = 1000;

/// Runs the benchmarks and returns their measures in Bencher Metric Format.
pub fn bench(c: &mut Criterion<Wall>) -> BTreeMap<String, serde_json::Value> {
    let mut group = c.benchmark_group(GROUP);
    group.sampling_mode(SamplingMode::Flat);
    let mut report = BTreeMap::new();

    for connectivity in CONNECTIVITIES {
        let id = connectivity.to_string();
        let mut idle = Idle::new(Tunnel::established(
            CLIENTS,
            connectivity,
            Resource::Cidr,
            true,
        ));
        let mut busy = Duration::ZERO;
        let mut simulated = Duration::ZERO;

        group.bench_function(&id, |b| {
            b.iter_custom(|iters| {
                // Whole keepalive periods, so that every sample covers all phases of the timers.
                let periods = iters.div_ceil(CLIENTS as u64 * KEEPALIVE.as_secs()).max(1);
                let duration = KEEPALIVE * u32::try_from(periods).unwrap();
                let measured = idle.run_for(duration);
                busy += measured;
                simulated += duration;

                measured.mul_f64(iters as f64 / (duration.as_secs_f64() * CLIENTS as f64))
            })
        });

        // Skipped or test runs simulate a single period at most.
        if simulated > KEEPALIVE {
            let ns = busy.as_nanos() as f64 / (simulated.as_secs_f64() * CLIENTS as f64);
            report.insert(
                format!("event_loop/{GROUP}/{id}"),
                serde_json::json!({ "event-loop-idle": { "value": ns } }),
            );
        }
    }

    report
}

/// An established [`Tunnel`], driven on from one timer to the next.
struct Idle {
    tunnel: Tunnel,
    gateway_deadline: Option<Instant>,
    client_deadlines: Vec<Option<Instant>>,
    /// Datagrams in flight, as source, destination and payload.
    in_flight: VecDeque<(SocketAddr, SocketAddr, Vec<u8>)>,
    /// The time spent in the Gateway's calls.
    busy: Duration,
}

impl Idle {
    fn new(mut tunnel: Tunnel) -> Self {
        let gateway_deadline = tunnel.gateway.poll_timeout().map(|(t, _)| t);
        let client_deadlines = tunnel
            .clients
            .iter_mut()
            .map(|client| client.state.poll_timeout().map(|(t, _)| t))
            .collect();

        Self {
            tunnel,
            gateway_deadline,
            client_deadlines,
            in_flight: VecDeque::new(),
            busy: Duration::ZERO,
        }
    }

    /// Lets `duration` of simulated time pass and returns the time spent in the Gateway's calls.
    fn run_for(&mut self, duration: Duration) -> Duration {
        let end = self.tunnel.now + duration;

        while let Some(next) = self
            .client_deadlines
            .iter()
            .chain([&self.gateway_deadline])
            .flatten()
            .min()
            .copied()
            .filter(|next| *next <= end)
        {
            self.tunnel.now = self.tunnel.now.max(next);
            let now = self.tunnel.now;

            if self.gateway_deadline.is_some_and(|t| t <= now) {
                self.wake_gateway(|gateway| {
                    gateway.handle_timeout(now);

                    false
                });
            }
            for index in 0..self.tunnel.clients.len() {
                if self.client_deadlines[index].is_some_and(|t| t <= now) {
                    self.tunnel.clients[index].state.handle_timeout(now);
                    self.flush_client(index);
                }
            }
            while let Some((from, to, payload)) = self.in_flight.pop_front() {
                self.deliver(from, to, &payload);
            }
        }
        self.tunnel.now = end;

        std::mem::take(&mut self.busy)
    }

    fn deliver(&mut self, from: SocketAddr, to: SocketAddr, payload: &[u8]) {
        let now = self.tunnel.now;

        if self.tunnel.relay.serves(to) {
            let datagrams = self.tunnel.relay.handle(from, to, payload, now);
            self.in_flight.extend(datagrams);

            return;
        }

        if to == *GATEWAY_SOCKET {
            // Like the event loop, lets the Gateway handle its timeouts after input it consumed.
            self.wake_gateway(|gateway| {
                match gateway.handle_network_input(to, from, payload, now) {
                    Ok(Some(decapsulation)) => matches!(
                        gateway.handle_peer_input(to, from, decapsulation.decrypt(payload), now),
                        Ok(None)
                    ),
                    Ok(None) => true,
                    Err(_) => false,
                }
            });

            return;
        }

        if let Some(index) = client_index(to).filter(|index| *index < self.tunnel.clients.len()) {
            receive(
                &mut self.tunnel.clients[index].state,
                to,
                from,
                payload,
                now,
            );
            self.flush_client(index);
        }
    }

    /// Times one wake-up of the Gateway's event loop: `input`, then its timeouts if `input` asks
    /// for them, then draining what it left.
    fn wake_gateway(&mut self, input: impl FnOnce(&mut GatewayState) -> bool) {
        let now = self.tunnel.now;
        let gateway = &mut self.tunnel.gateway;
        let mut transmits = Vec::new();

        let start = Instant::now();
        if input(gateway) {
            gateway.handle_timeout(now);
        }
        for _ in std::iter::from_fn(|| gateway.poll_event()) {}
        transmits.extend(std::iter::from_fn(|| gateway.poll_transmit()));
        self.gateway_deadline = gateway.poll_timeout().map(|(t, _)| t);
        self.busy += start.elapsed();

        for transmit in transmits {
            self.in_flight
                .push_back((*GATEWAY_SOCKET, transmit.dst, transmit.payload.to_vec()));
        }
    }

    fn flush_client(&mut self, index: usize) {
        let client = &mut self.tunnel.clients[index].state;

        for _ in std::iter::from_fn(|| client.poll_event()) {}
        for _ in std::iter::from_fn(|| client.poll_packets()) {}
        while let Some(transmit) = client.poll_transmit() {
            self.in_flight.push_back((
                client_socket(index),
                transmit.dst,
                transmit.payload.to_vec(),
            ));
        }
        self.client_deadlines[index] = client.poll_timeout().map(|(t, _)| t);
    }
}
