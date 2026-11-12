use std::time::Duration;

use arbitrary::Unstructured;

/// What can happen to the client, the relay and the network between them.
///
/// Credential rotation is missing: an `Allocation` cannot take new credentials.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Transition {
    /// Delivers datagrams in both directions until none are in flight.
    Settle,
    /// Delivers the oldest datagram in flight in one direction.
    Deliver(Direction),
    /// Loses the oldest datagram in flight in one direction.
    Drop(Direction),
    /// Loses all datagrams in flight.
    DropAll,
    /// Lets time pass, stopping at every timer of the client and the relay.
    Advance {
        duration: Duration,
        /// Whether the network delivers what is sent in the meantime.
        deliver: bool,
    },
    /// The client checks whether the relay still holds its allocation.
    Refresh,
    BindChannel {
        peer: usize,
    },
    /// The client sends data to a peer through the relay.
    SendToPeer {
        peer: usize,
    },
    /// A peer sends data to the client's relayed address.
    PeerSends {
        peer: usize,
    },
    /// The client moves to new sockets and starts over.
    Roam {
        v4: bool,
        v6: bool,
    },
    /// The relay restarts: it forgets everything and generates a new secret.
    RebootRelay,
    /// The portal tells the client about the relay.
    ///
    /// A relay the client is connected to is left alone; a rebooted one counts as a new relay.
    AnnounceRelay,
    /// Whether the relay answers new allocations with `508 Insufficient Capacity`.
    SetRelayCapacity {
        exhausted: bool,
    },
    GarbageToRelay {
        sender: Sender,
        /// Decode the datagram as a STUN message and re-encode it before handing it over.
        parse: bool,
        /// Give the message a nonce the relay issued and a matching HMAC.
        authenticate: bool,
        datagram: Garbage,
    },
    /// A datagram to the client, claiming to be from the relay.
    GarbageToClient(Garbage),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Direction {
    ToRelay,
    ToClient,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Sender {
    /// A socket on the internet that has nothing to do with the client.
    Foreign,
    /// The client's own socket, as if the client had gone out of sync with the relay.
    Client,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Garbage {
    /// Start from the last datagram the impersonated side sent instead of from nothing.
    pub(crate) mutate_last: bool,
    pub(crate) bytes: Vec<u8>,
}

impl Transition {
    /// Reads one transition from the input; an exhausted input yields [`Transition::Settle`].
    pub(crate) fn arbitrary(u: &mut Unstructured<'_>) -> Self {
        const DURATIONS: [u64; 8] = [1, 2, 5, 10, 30, 120, 400, 1000];

        match int(u, 31) {
            0..=7 => Self::Settle,
            8..=9 => Self::Deliver(Direction::ToRelay),
            10..=11 => Self::Deliver(Direction::ToClient),
            12 => Self::Drop(Direction::ToRelay),
            13 => Self::Drop(Direction::ToClient),
            14 => Self::DropAll,
            15..=18 => Self::Advance {
                duration: Duration::from_secs(DURATIONS[int(u, 7)]),
                deliver: bool(u),
            },
            19 => Self::Refresh,
            20 => Self::BindChannel { peer: int(u, 255) },
            21..=22 => Self::SendToPeer { peer: int(u, 255) },
            23 => Self::PeerSends { peer: int(u, 255) },
            24 => Self::Roam {
                v4: bool(u),
                v6: bool(u),
            },
            25 => Self::RebootRelay,
            26 => Self::AnnounceRelay,
            27 => Self::SetRelayCapacity { exhausted: bool(u) },
            28..=29 => Self::GarbageToRelay {
                sender: if bool(u) {
                    Sender::Client
                } else {
                    Sender::Foreign
                },
                parse: bool(u),
                authenticate: bool(u),
                datagram: Garbage::arbitrary(u),
            },
            _ => Self::GarbageToClient(Garbage::arbitrary(u)),
        }
    }
}

impl Garbage {
    fn arbitrary(u: &mut Unstructured<'_>) -> Self {
        let mutate_last = bool(u);
        let len = int(u, 255).min(u.len());
        let bytes = u.bytes(len).unwrap_or_default().to_vec();

        Self { mutate_last, bytes }
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
