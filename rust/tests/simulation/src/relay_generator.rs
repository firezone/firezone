use std::{
    net::{Ipv4Addr, Ipv6Addr},
    time::Duration,
};

use arbitrary::Unstructured;
use connlib_model::IpStack;

use crate::{
    relay_model::{ModelHost, RelayModel},
    relay_transition::{BitFlips, Crafting, Interference, Target, Template, Transition},
};

/// Samples the relay simulation's setup and transitions from the input.
pub(crate) struct RelayGenerator<'a> {
    input: Unstructured<'a>,
}

impl<'a> RelayGenerator<'a> {
    pub(crate) fn new(data: &'a [u8]) -> Self {
        Self {
            input: Unstructured::new(data),
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.input.is_empty()
    }

    pub(crate) fn model(&mut self) -> RelayModel {
        let relay = ModelHost {
            ip4: Ipv4Addr::new(198, 51, 100, 1),
            ip6: Ipv6Addr::new(0x2001, 0xdb8, 1, 0, 0, 0, 0, 1),
            port: 3478,
            stack: self.ip_stack(),
            latency: self.latency(50),
        };
        let client = ModelHost {
            ip4: Ipv4Addr::new(203, 0, 113, 10),
            ip6: Ipv6Addr::new(0x2001, 0xdb8, 2, 0, 0, 0, 0, 10),
            port: 50000,
            stack: self.ip_stack(),
            latency: self.latency(250),
        };
        let foreign = ModelHost {
            ip4: Ipv4Addr::new(203, 0, 113, 200),
            ip6: Ipv6Addr::new(0x2001, 0xdb8, 2, 0, 0, 0, 0, 200),
            port: 7000,
            stack: IpStack::Dual,
            latency: Duration::ZERO,
        };
        let peer = ModelHost {
            ip4: Ipv4Addr::new(192, 0, 2, 10),
            ip6: Ipv6Addr::new(0x2001, 0xdb8, 3, 0, 0, 0, 0, 10),
            port: 40000,
            stack: IpStack::Dual,
            latency: Duration::ZERO,
        };

        RelayModel {
            relay,
            client,
            foreign,
            peer,
        }
    }

    pub(crate) fn transition(&mut self) -> (Transition, Interference) {
        const ADVANCE_SECS: [u64; 8] = [5, 30, 120, 360, 660, 960, 1860, 3660];
        const PARTITION_SECS: [u64; 4] = [2, 9, 40, 720];

        let transition = match self.int(12) {
            0..=4 => Transition::Advance {
                duration: Duration::from_secs(ADVANCE_SECS[self.int(7)]),
            },
            5..=6 => Transition::Refresh,
            7 => Transition::Roam {
                stack: match (self.bool(), self.bool()) {
                    (true, false) => IpStack::Ipv4Only,
                    (false, true) => IpStack::Ipv6Only,
                    (true, true) | (false, false) => IpStack::Dual,
                },
            },
            8 => Transition::RebootRelay,
            9 => Transition::Partition {
                duration: Duration::from_secs(PARTITION_SECS[self.int(3)]),
            },
            _ => Transition::Inject {
                target: match self.int(2) {
                    0 => Target::RelayFromForeign(self.crafting()),
                    1 => Target::RelayFromClient(self.crafting()),
                    _ => Target::Client,
                },
                flips: self.bit_flips(),
            },
        };
        let interference = Interference {
            lose_to_relay: self.bool(),
            lose_to_client: self.bool(),
            forge_to_client: self.bool().then(|| self.bit_flips()),
        };

        (transition, interference)
    }

    /// The address families of a host.
    fn ip_stack(&mut self) -> IpStack {
        match self.int(2) {
            1 => IpStack::Ipv4Only,
            2 => IpStack::Ipv6Only,
            _ => IpStack::Dual,
        }
    }

    fn latency(&mut self, max: u64) -> Duration {
        Duration::from_millis(self.input.int_in_range(10..=max - 1).unwrap_or(10))
    }

    fn crafting(&mut self) -> Crafting {
        Crafting {
            parse: self.bool(),
            template: match self.bool() {
                true => Template::LastFromClient,
                false => Template::Nothing,
            },
        }
    }

    fn bit_flips(&mut self) -> BitFlips {
        let len = self.int(255).min(self.input.len());
        let mask = self.input.bytes(len).unwrap_or_default().to_vec();

        BitFlips { mask }
    }

    fn int(&mut self, max: u8) -> usize {
        usize::from(self.input.int_in_range(0..=max).unwrap_or(0))
    }

    fn bool(&mut self) -> bool {
        self.int(1) == 1
    }
}
