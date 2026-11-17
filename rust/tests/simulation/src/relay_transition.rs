use std::time::Duration;

use connlib_model::IpStack;

/// What can happen to the client, the relay, the portal and the network between them.
///
/// Every transition runs until the client and the relay have settled.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Transition {
    /// Time passes on a working network.
    Advance {
        duration: Duration,
    },
    /// The portal issues credentials with a later expiry.
    ///
    /// An `Allocation` cannot take new credentials, so they replace the allocation.
    RotateCredentials,
    /// The portal sends a relay update that does not mention the relay, which makes the client
    /// check whether the relay still holds its allocation.
    Refresh,
    /// The client moves to new sockets and starts over.
    Roam {
        stack: IpStack,
    },
    /// The relay restarts: it forgets everything and generates a new secret.
    ///
    /// To the portal, that is a new relay with new credentials.
    RebootRelay,
    /// No datagram makes it between the client and the relay for a while.
    Partition {
        duration: Duration,
    },
    /// The portal can no longer reach the client.
    PortalOutage,
    PortalRecovers,
    /// A datagram that neither the client nor the relay sent.
    Garbage {
        target: Target,
        datagram: Garbage,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Target {
    /// To the relay, from a socket on the internet that has nothing to do with the client.
    RelayFromForeign(Crafting),
    /// To the relay, from the client's own socket and device, as if the two had gone out of sync.
    RelayFromClient(Crafting),
    /// To the client, claiming to be from the relay.
    Client,
}

/// How a datagram to the relay is made from the garbage.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Crafting {
    /// Decode the datagram as a STUN message and re-encode it before handing it over.
    pub(crate) parse: bool,
    /// Give the message a nonce the relay issued and a matching HMAC.
    pub(crate) authenticate: bool,
    /// Start from the last control datagram the client sent instead of from nothing.
    pub(crate) mutate: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Garbage {
    pub(crate) bytes: Vec<u8>,
}

/// What the network does to the control datagrams of a transition, at most to the first one
/// in each direction.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct Interference {
    pub(crate) lose_to_relay: bool,
    pub(crate) lose_to_client: bool,
    /// Delivers a copy of the first one that reaches the client ahead of it, with the garbage
    /// applied.
    pub(crate) forge_to_client: Option<Garbage>,
}

impl Garbage {
    /// Flips the bits of `template` that are set in our bytes; what we have beyond it is appended.
    pub(crate) fn apply_to(&self, template: &[u8]) -> Vec<u8> {
        let mut datagram = template.to_vec();
        datagram.resize(template.len().max(self.bytes.len()), 0);

        for (byte, mask) in datagram.iter_mut().zip(&self.bytes) {
            *byte ^= mask;
        }

        datagram
    }
}
