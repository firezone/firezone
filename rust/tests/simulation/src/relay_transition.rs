use std::time::Duration;

use connlib_model::IpStack;

/// What can happen to the client, the relay and the network between them.
///
/// Every transition runs until the client and the relay have settled.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Transition {
    /// Time passes on a working network.
    Advance { duration: Duration },
    /// The client calls `Allocation::refresh`.
    Refresh,
    /// The client moves to new sockets and calls `Allocation::restart`.
    Roam { stack: IpStack },
    /// The relay restarts: it forgets everything and generates a new secret.
    RebootRelay,
    /// No datagram makes it between the client and the relay for a while.
    Partition { duration: Duration },
    /// A datagram that neither the client nor the relay sent.
    Inject { target: Target, flips: BitFlips },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Target {
    /// To the relay, from a socket on the internet that has nothing to do with the client.
    RelayFromForeign(Crafting),
    /// To the relay, from the client's own socket, where it meets the client's allocation and
    /// channels.
    RelayFromClient(Crafting),
    /// To the client, claiming to be from the relay.
    Client,
}

/// How a datagram to the relay is made from the bit flips.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Crafting {
    /// Decode the datagram as a STUN message and re-encode it before handing it over.
    pub(crate) parse: bool,
    pub(crate) template: Template,
}

/// The datagram that the bit flips apply to.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Template {
    Nothing,
    /// The last control datagram the client sent; without flips, that is a replay.
    LastFromClient,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct BitFlips {
    pub(crate) mask: Vec<u8>,
}

/// What the network does to the control datagrams of a transition, at most to the first one
/// in each direction.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct Interference {
    pub(crate) lose_to_relay: bool,
    pub(crate) lose_to_client: bool,
    /// Delivers a copy of the first one that reaches the client ahead of it, with these bits
    /// flipped.
    pub(crate) forge_to_client: Option<BitFlips>,
}

impl BitFlips {
    /// Flips the bits of `template` that are set in the mask; what the mask has beyond it is
    /// appended.
    pub(crate) fn apply_to(&self, template: &[u8]) -> Vec<u8> {
        let mut datagram = template.to_vec();
        datagram.resize(template.len().max(self.mask.len()), 0);

        for (byte, mask) in datagram.iter_mut().zip(&self.mask) {
            *byte ^= mask;
        }

        datagram
    }
}
