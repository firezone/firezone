use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};

use crate::stun;

/// What can happen to the client, the relay and the network between them.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Transition {
    /// Time passes on a working network.
    Advance { duration: Duration },
    /// The client moves to new sockets on these interfaces and calls `Allocation::restart`.
    Roam {
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
    },
    /// The portal issues the client credentials that are valid for `lifetime` and hands them to
    /// it, as it does for a relay that the client keeps.
    RotateCredentials { lifetime: Duration },
    /// The relay restarts: it forgets everything and generates a new secret.
    RebootRelay,
    /// No datagram makes it between the client and the relay for a while.
    Partition { duration: Duration },
    /// The client and a peer start to exchange data.
    Connect { peer: SocketAddr },
    /// The client and a peer stop to exchange data. TURN cannot unbind their channel.
    Disconnect { peer: SocketAddr },
    /// A datagram that neither the client nor the relay sent.
    InjectDatagram(Injection),
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Injection {
    /// To the relay, from a socket on the internet that has nothing to do with the client.
    RelayFromForeign(RelayDatagram),
    /// To the relay, from the client's own socket, where it meets the client's allocation and
    /// channels.
    RelayFromClient(RelayDatagram),
    /// To the client, claiming to be from the relay.
    Client(Vec<u8>),
    /// Relayable data to the client's relay addresses, from the foreign socket.
    RelayAddresses,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum RelayDatagram {
    Raw(Vec<u8>),
    /// Decoded as a STUN message and encoded again.
    Stun(Vec<u8>),
    /// A request of the foreign device, which has credentials of its own and a nonce that the
    /// relay issued to the foreign socket.
    Request(ForeignRequest),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum ForeignRequest {
    Allocate,
    Refresh { lifetime: Duration },
    ChannelBind { channel: u16, peer: SocketAddr },
}

/// What the network does to the control datagrams between the client and the relay, counted
/// from the start of a transition.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct Interference {
    /// How many of the client's it loses.
    pub(crate) lose_to_relay: u8,
    /// How many of the relay's it loses.
    pub(crate) lose_to_client: u8,
    /// Delivers a forgery of the first one that reaches the client ahead of it.
    pub(crate) forge_to_client: Option<Forgery>,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Forgery {
    /// The relay's datagram with the bits flipped that are set in the mask; what the mask has
    /// beyond it is appended.
    BitFlips(Vec<u8>),
    /// An error response to the request that the relay's datagram answers, without
    /// `MESSAGE-INTEGRITY`.
    Error { code: u16 },
}

impl Forgery {
    pub(crate) fn apply_to(&self, template: &[u8]) -> Option<Vec<u8>> {
        match self {
            Forgery::BitFlips(mask) => {
                let mut datagram = template.to_vec();
                datagram.resize(template.len().max(mask.len()), 0);

                for (byte, mask) in datagram.iter_mut().zip(mask) {
                    *byte ^= mask;
                }

                Some(datagram)
            }
            Forgery::Error { code } => stun::error_response(template, *code),
        }
    }
}
