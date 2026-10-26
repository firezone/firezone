use std::time::Duration;

use crate::fixture::{Connectivity, KEEPALIVE, Network, Resource};

/// How long a benchmark keeps the connections idle: whole keepalive periods, so that it covers
/// every phase of the connections' timers.
const DURATION: Duration = Duration::from_secs(5 * KEEPALIVE.as_secs());

/// Idle connections from Clients to a Gateway, of which only the Gateway is counted.
pub struct Idle {
    network: Network,
}

impl Idle {
    pub fn new(connectivity: Connectivity, clients: usize) -> Self {
        let network = Network::established(clients, connectivity, Resource::Cidr);

        Self { network }
    }

    /// Lets [`DURATION`] of simulated time pass.
    pub fn run(&mut self) {
        self.network.run_until(self.network.now + DURATION);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connections_stay_up() {
        let mut idle = Idle::new(Connectivity::Ice, 3);
        idle.run();

        let network = &mut idle.network;
        for index in 0..network.clients.len() {
            assert_eq!(network.forward(index).len(), 1);
        }
    }
}
