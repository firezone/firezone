//! What connlib expects of a relay client: an allocation that relays data and heals itself.
//!
//! The model answers two questions per transition, see [`Reference::must_relay`] and
//! [`Reference::apply`]. It describes how the client behaves today, flaws included, so that
//! fixing one shows up as a change here.

use crate::relay_transition::{Target, Transition};

/// What the expectations depend on besides the transitions.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Environment {
    /// Whether the client and the relay share an address family.
    pub(crate) relay_reachable: bool,
    pub(crate) portal_reachable: bool,
    /// Whether the credentials that the portal last issued are unexpired and for the running relay.
    pub(crate) credentials_valid: bool,
}

/// What happened while a transition ran.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct Observed {
    /// The network lost one of the control datagrams.
    pub(crate) lost_datagram: bool,
    /// The client's credentials were invalid at some point.
    pub(crate) credentials_lapsed: bool,
    /// The client saw a forged answer to a `BINDING` request.
    pub(crate) forged_binding: bool,
}

#[derive(Debug, Default)]
pub(crate) struct Reference {
    /// Whether the client may have given up on the relay while the portal could not hand it back.
    stranded: bool,
}

impl Reference {
    /// Whether relaying must work once a transition has settled.
    ///
    /// With the portal around, the client always recovers: it is handed the relay again, with
    /// fresh credentials. Without it, the client depends on what it already holds.
    pub(crate) fn must_relay(&self, env: Environment) -> bool {
        env.relay_reachable && (env.portal_reachable || (env.credentials_valid && !self.stranded))
    }

    /// Applies a transition, returning whether it was allowed to interrupt relaying.
    pub(crate) fn apply(
        &mut self,
        transition: &Transition,
        env: Environment,
        observed: Observed,
    ) -> bool {
        let may_interrupt = match transition {
            // An allocation cannot take new credentials, so they replace it.
            Transition::RotateCredentials => true,
            Transition::Roam { .. }
            | Transition::RebootRelay
            | Transition::Partition { .. }
            | Transition::Garbage {
                target: Target::RelayFromClient,
                ..
            } => true,
            // The client gives up on the relay if a single datagram of this check is lost.
            Transition::Refresh => observed.lost_datagram,
            Transition::Advance { .. }
            | Transition::PortalOutage
            | Transition::PortalRecovers
            | Transition::Garbage {
                target: Target::RelayFromForeign | Target::Client,
                ..
            } => false,
        };
        let may_interrupt = may_interrupt || observed.credentials_lapsed || self.stranded;

        // The client gives up on a relay that does not answer. `BINDING` is not authenticated,
        // so a forged answer keeps the client from ever seeing the real one.
        let relay_was_silent = matches!(transition, Transition::Partition { .. })
            || !env.relay_reachable
            || observed.forged_binding;

        if matches!(transition, Transition::PortalRecovers) {
            self.stranded = false;
        }
        if relay_was_silent && !env.portal_reachable {
            self.stranded = true;
        }

        may_interrupt
    }
}
