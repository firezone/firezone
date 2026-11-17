use std::time::Duration;

use arbitrary::Unstructured;
use connlib_model::IpStack;

use crate::relay_transition::{Crafting, Garbage, Interference, Target, Transition};

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

    /// The address families of a host.
    pub(crate) fn ip_stack(&mut self) -> IpStack {
        match self.int(2) {
            1 => IpStack::Ipv4Only,
            2 => IpStack::Ipv6Only,
            _ => IpStack::Dual,
        }
    }

    pub(crate) fn transition(&mut self) -> (Transition, Interference) {
        const ADVANCE_SECS: [u64; 8] = [5, 30, 120, 360, 660, 960, 1860, 3660];
        const PARTITION_SECS: [u64; 4] = [2, 9, 40, 720];

        let transition = match self.int(15) {
            0..=4 => Transition::Advance {
                duration: Duration::from_secs(ADVANCE_SECS[self.int(7)]),
            },
            5 => Transition::RotateCredentials,
            6..=7 => Transition::Refresh,
            8 => Transition::Roam {
                stack: match (self.bool(), self.bool()) {
                    (true, false) => IpStack::Ipv4Only,
                    (false, true) => IpStack::Ipv6Only,
                    (true, true) | (false, false) => IpStack::Dual,
                },
            },
            9 => Transition::RebootRelay,
            10 => Transition::Partition {
                duration: Duration::from_secs(PARTITION_SECS[self.int(3)]),
            },
            11 => Transition::PortalOutage,
            12 => Transition::PortalRecovers,
            _ => Transition::Garbage {
                target: match self.int(2) {
                    0 => Target::RelayFromForeign(self.crafting()),
                    1 => Target::RelayFromClient(self.crafting()),
                    _ => Target::Client,
                },
                datagram: self.garbage(),
            },
        };
        let interference = Interference {
            lose_to_relay: self.bool(),
            lose_to_client: self.bool(),
            forge_to_client: self.bool().then(|| self.garbage()),
        };

        (transition, interference)
    }

    fn crafting(&mut self) -> Crafting {
        Crafting {
            parse: self.bool(),
            authenticate: self.bool(),
            mutate: self.bool(),
        }
    }

    fn garbage(&mut self) -> Garbage {
        let len = self.int(255).min(self.input.len());
        let bytes = self.input.bytes(len).unwrap_or_default().to_vec();

        Garbage { bytes }
    }

    fn int(&mut self, max: u8) -> usize {
        usize::from(self.input.int_in_range(0..=max).unwrap_or(0))
    }

    fn bool(&mut self) -> bool {
        self.int(1) == 1
    }
}
