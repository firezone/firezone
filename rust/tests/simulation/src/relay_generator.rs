use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};

use arbitrary::Unstructured;
use connlib_model::IpStack;

use crate::{
    relay_model::{ModelHost, PEERS, RelayModel},
    relay_transition::{
        ForeignRequest, Forgery, Injection, Interference, RelayDatagram, Transition,
    },
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

        RelayModel::new(relay, client, foreign)
    }

    /// Samples a transition, what the network does to it and whether the system settles and
    /// is checked before the next one.
    pub(crate) fn transition(&mut self, model: &RelayModel) -> (Transition, Interference, bool) {
        let transition = match self.int(15) {
            0..=5 => Transition::Advance {
                duration: self.duration(),
            },
            6 => Transition::Refresh,
            7 => {
                let (ip4, ip6) = model.client.interfaces(self.ip_stack());

                Transition::Roam { ip4, ip6 }
            }
            8 => Transition::RebootRelay,
            9 => Transition::Partition {
                duration: self.duration(),
            },
            10 => Transition::Connect { peer: self.peer() },
            11 => Transition::Disconnect { peer: self.peer() },
            _ => Transition::InjectDatagram(match self.int(3) {
                0 => Injection::RelayFromForeign(self.relay_datagram()),
                1 => Injection::RelayFromClient(self.relay_datagram()),
                2 => Injection::Client(self.bytes()),
                _ => Injection::RelayAddresses,
            }),
        };
        let interference = Interference {
            lose_to_relay: self.losses(),
            lose_to_client: self.losses(),
            forge_to_client: match self.int(3) {
                0..=1 => None,
                2 => Some(Forgery::BitFlips(self.bytes())),
                _ => Some(Forgery::Error {
                    code: self.error_code(),
                }),
            },
        };
        let settle = self.int(3) < 3;

        (transition, interference, settle)
    }

    fn relay_datagram(&mut self) -> RelayDatagram {
        match self.int(5) {
            0 => RelayDatagram::Raw(self.bytes()),
            1 => RelayDatagram::Stun(self.bytes()),
            2 => RelayDatagram::Request(ForeignRequest::Allocate),
            3 => RelayDatagram::Request(ForeignRequest::Refresh {
                lifetime: Duration::ZERO,
            }),
            4 => RelayDatagram::Request(ForeignRequest::Refresh {
                lifetime: Duration::from_secs(600),
            }),
            _ => RelayDatagram::Request(ForeignRequest::ChannelBind {
                channel: 0x4000 + self.int(7) as u16,
                peer: self.peer(),
            }),
        }
    }

    /// A duration on one of three scales: short enough to interrupt a handshake, or long
    /// enough to reach what expires.
    fn duration(&mut self) -> Duration {
        match self.int(2) {
            0 => Duration::from_millis(4) * (self.int(249) as u32 + 1),
            1 => Duration::from_secs(1) * (self.int(255) as u32 + 1),
            _ => Duration::from_secs(60) * (self.int(60) as u32 + 1),
        }
    }

    /// How many datagrams the network loses, mostly none.
    fn losses(&mut self) -> u8 {
        (self.int(9) as u8).saturating_sub(5)
    }

    fn error_code(&mut self) -> u16 {
        const CODES: [u16; 11] = [300, 400, 401, 403, 420, 437, 438, 441, 486, 500, 508];

        CODES[self.int(10)]
    }

    fn peer(&mut self) -> SocketAddr {
        PEERS[self.int(3)]
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

    fn bytes(&mut self) -> Vec<u8> {
        let len = self.int(255).min(self.input.len());

        self.input.bytes(len).unwrap_or_default().to_vec()
    }

    fn int(&mut self, max: u8) -> usize {
        usize::from(self.input.int_in_range(0..=max).unwrap_or(0))
    }
}
