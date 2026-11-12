use std::time::Duration;

use arbitrary::Unstructured;

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
        v4: bool,
        v6: bool,
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
        /// Decode the datagram as a STUN message and re-encode it before handing it over.
        parse: bool,
        /// Give the message a nonce the relay issued and a matching HMAC.
        authenticate: bool,
        datagram: Garbage,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Target {
    /// To the relay, from a socket on the internet that has nothing to do with the client.
    RelayFromForeign,
    /// To the relay, from the client's own socket and device, as if the two had gone out of sync.
    RelayFromClient,
    /// To the client, claiming to be from the relay.
    Client,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Garbage {
    /// Start from a real datagram instead of from nothing.
    ///
    /// For the relay, that is the last one the client sent. For the client, it is the next
    /// one the relay sends: the client then sees the mutated copy first.
    pub(crate) mutate: bool,
    pub(crate) bytes: Vec<u8>,
}

/// The control datagrams a transition loses, at most the first one it causes in each direction.
///
/// Requests are retransmitted, so what must hold after a transition does not depend on this.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub(crate) struct Loss {
    pub(crate) to_relay: bool,
    pub(crate) to_client: bool,
}

impl Transition {
    pub(crate) fn arbitrary(u: &mut Unstructured<'_>) -> (Self, Loss) {
        const ADVANCE_SECS: [u64; 8] = [5, 30, 120, 360, 660, 960, 1860, 3660];
        const PARTITION_SECS: [u64; 4] = [2, 9, 40, 720];

        let transition = match int(u, 15) {
            0..=4 => Self::Advance {
                duration: Duration::from_secs(ADVANCE_SECS[int(u, 7)]),
            },
            5 => Self::RotateCredentials,
            6..=7 => Self::Refresh,
            8 => Self::Roam {
                v4: bool(u),
                v6: bool(u),
            },
            9 => Self::RebootRelay,
            10 => Self::Partition {
                duration: Duration::from_secs(PARTITION_SECS[int(u, 3)]),
            },
            11 => Self::PortalOutage,
            12 => Self::PortalRecovers,
            _ => Self::Garbage {
                target: match int(u, 2) {
                    0 => Target::RelayFromForeign,
                    1 => Target::RelayFromClient,
                    _ => Target::Client,
                },
                parse: bool(u),
                authenticate: bool(u),
                datagram: Garbage::arbitrary(u),
            },
        };
        let loss = Loss {
            to_relay: bool(u),
            to_client: bool(u),
        };

        (transition, loss)
    }
}

impl Garbage {
    fn arbitrary(u: &mut Unstructured<'_>) -> Self {
        let mutate = bool(u);
        let len = int(u, 255).min(u.len());
        let bytes = u.bytes(len).unwrap_or_default().to_vec();

        Self { mutate, bytes }
    }
}

/// Whether a host has IPv4 and IPv6.
pub(crate) fn stack(u: &mut Unstructured<'_>) -> (bool, bool) {
    match int(u, 2) {
        1 => (true, false),
        2 => (false, true),
        _ => (true, true),
    }
}

fn int(u: &mut Unstructured<'_>, max: u8) -> usize {
    usize::from(u.int_in_range(0..=max).unwrap_or(0))
}

fn bool(u: &mut Unstructured<'_>) -> bool {
    int(u, 1) == 1
}
