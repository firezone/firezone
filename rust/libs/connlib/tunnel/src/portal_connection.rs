use connlib_model::IceCandidate;
use std::collections::{BTreeMap, BTreeSet};

/// Tracks whether we currently have a live connection to the portal.
///
/// ICE candidates are signalled to peers through the portal, so while it is
/// disconnected any candidate change would be lost. In that state we hold the
/// changes back per connection and flush them once the portal reconnects, so a
/// peer we roamed away from learns our new addresses and forgets the ones that
/// became unreachable.
#[derive(Default)]
pub(crate) enum PortalConnection<Id> {
    #[default]
    Connected,
    Disconnected(HeldCandidates<Id>),
}

/// Candidate changes held back per connection while the portal is disconnected.
pub(crate) struct HeldCandidates<Id> {
    /// New candidates gathered while disconnected, to signal as added on reconnect.
    pub(crate) added: BTreeMap<Id, BTreeSet<IceCandidate>>,
    /// Previously-signalled candidates invalidated while disconnected, to signal as
    /// removed on reconnect.
    pub(crate) removed: BTreeMap<Id, BTreeSet<IceCandidate>>,
}

impl<Id> Default for HeldCandidates<Id> {
    fn default() -> Self {
        Self {
            added: BTreeMap::new(),
            removed: BTreeMap::new(),
        }
    }
}

impl<Id: Ord> PortalConnection<Id> {
    pub(crate) fn is_connected(&self) -> bool {
        matches!(self, Self::Connected)
    }

    /// Records a newly gathered candidate to signal on reconnect.
    ///
    /// Only has an effect while disconnected; when connected the candidate is signalled
    /// immediately by the caller instead.
    pub(crate) fn hold_added(&mut self, connection: Id, candidate: IceCandidate) {
        let Self::Disconnected(held) = self else {
            return;
        };

        if let Some(removed) = held.removed.get_mut(&connection) {
            removed.remove(&candidate);
        }
        held.added.entry(connection).or_default().insert(candidate);
    }

    /// Records an invalidated candidate to signal on reconnect.
    pub(crate) fn hold_removed(&mut self, connection: Id, candidate: IceCandidate) {
        let Self::Disconnected(held) = self else {
            return;
        };

        // A candidate we were still holding back was never signalled, so cancelling it
        // locally is enough; only signal the removal for ones the peer already learned.
        let was_held_add = held
            .added
            .get_mut(&connection)
            .is_some_and(|added| added.remove(&candidate));

        if !was_held_add {
            held.removed
                .entry(connection)
                .or_default()
                .insert(candidate);
        }
    }

    /// Drops any candidates held for a connection that no longer exists.
    pub(crate) fn forget(&mut self, connection: &Id) {
        let Self::Disconnected(held) = self else {
            return;
        };

        held.added.remove(connection);
        held.removed.remove(connection);
    }

    /// Marks the portal disconnected, starting to hold candidate changes back.
    ///
    /// Keeps any already-held candidates if we were already disconnected.
    pub(crate) fn disconnect(&mut self) {
        if let Self::Connected = self {
            *self = Self::Disconnected(HeldCandidates::default());
        }
    }

    /// Marks the portal connected, returning the candidates held during the outage so
    /// the caller can flush them to their peers.
    ///
    /// Returns an empty set if we were already connected.
    pub(crate) fn connect(&mut self) -> HeldCandidates<Id> {
        match std::mem::replace(self, Self::Connected) {
            Self::Connected => HeldCandidates::default(),
            Self::Disconnected(held) => held,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn holds_candidate_changes_and_flushes_them_on_reconnect() {
        let mut portal = PortalConnection::<u8>::default();
        assert!(portal.is_connected());

        portal.disconnect();
        assert!(!portal.is_connected());

        portal.hold_added(1, "added".to_owned().into());
        portal.hold_removed(1, "removed".to_owned().into());

        let held = portal.connect();
        assert!(portal.is_connected());
        assert_eq!(held.added[&1].len(), 1);
        assert_eq!(held.removed[&1].len(), 1);
    }

    #[test]
    fn invalidating_a_still_held_addition_cancels_it() {
        let mut portal = PortalConnection::<u8>::default();
        portal.disconnect();

        portal.hold_added(1, "c".to_owned().into());
        portal.hold_removed(1, "c".to_owned().into());

        let held = portal.connect();
        assert!(held.added.get(&1).is_none_or(BTreeSet::is_empty));
        assert!(held.removed.get(&1).is_none_or(BTreeSet::is_empty));
    }
}
