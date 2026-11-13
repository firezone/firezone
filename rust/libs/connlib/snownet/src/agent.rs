//! Connection-level agent dispatch over `Agent::Ice` (str0m) or
//! `Agent::Frostlink`. Mode-irrelevant operations are no-ops on
//! the wrong variant.

use std::collections::BTreeSet;
use std::net::SocketAddr;
use std::time::Instant;

use is::stun::StunPacket;
use is::{Candidate, IceAgent, IceAgentEvent, IceConnectionState, IceCreds};

use crate::{IceConfig, IceRole};

/// Where a local candidate came from.
#[derive(Debug, Clone, Copy)]
pub(crate) enum CandidateOrigin {
    /// Learned from a relay allocation.
    Gathered,
    /// An additional host candidate configured by an admin.
    ManuallyConfigured,
}

impl CandidateOrigin {
    /// Frostlink ranks manually configured candidates above all others.
    fn frostlink_local_preference(self) -> u16 {
        match self {
            CandidateOrigin::Gathered => 0,
            CandidateOrigin::ManuallyConfigured => u16::MAX,
        }
    }
}

#[derive(derive_more::Debug)]
pub(crate) enum Agent {
    Ice(
        IceAgent,
        /// The paths refused so far; see [`Agent::refuse_path`].
        #[debug(skip)]
        BTreeSet<(SocketAddr, SocketAddr)>,
    ),
    Frostlink(#[debug(skip)] frostlink::Agent),
}

impl Agent {
    pub(crate) fn ice(agent: IceAgent) -> Self {
        Self::Ice(agent, BTreeSet::new())
    }

    pub(crate) fn frostlink() -> Self {
        Self::Frostlink(frostlink::Agent::new())
    }

    pub(crate) fn is_frostlink(&self) -> bool {
        matches!(self, Self::Frostlink(_))
    }

    /// Rebuild the inner `frostlink::Agent`, dropping locals matching
    /// `should_drop_local` and preserving every remote. No-op on `Self::Ice`.
    pub(crate) fn rebuild_frostlink(
        &mut self,
        should_drop_local: impl FnMut(&frostlink::Candidate) -> bool,
        now: Instant,
    ) {
        if let Self::Frostlink(agent) = self {
            agent.rebuild(should_drop_local, now);
        }
    }

    pub(crate) fn is_negotiation_complete(&self) -> bool {
        match self {
            Self::Ice(a, _) => a.state() == IceConnectionState::Connected,
            Self::Frostlink(agent) => agent.primary().is_some(),
        }
    }

    pub(crate) fn apply_ice_config(&mut self, config: IceConfig) {
        if let Self::Ice(a, _) = self {
            a.set_max_stun_retransmits(config.max_retrans);
            a.set_max_stun_rto(config.max_rto);
            a.set_initial_stun_rto(config.initial_rto);
        }
    }

    /// A mismatched `want_frostlink` forces replacement so a flag flip
    /// between upserts actually takes effect.
    pub(crate) fn matches_existing_connection(
        &self,
        local_creds: &IceCreds,
        remote_creds: &IceCreds,
        ice_role: IceRole,
        want_frostlink: bool,
    ) -> bool {
        if self.is_frostlink() != want_frostlink {
            return false;
        }
        match self {
            Self::Ice(a, _) => {
                a.local_credentials() == local_creds
                    && a.remote_credentials().is_some_and(|c| c == remote_creds)
                    && a.controlling() == matches!(ice_role, IceRole::Controlling)
            }
            Self::Frostlink(_) => true,
        }
    }

    /// Frostlink fans the init out from `upsert_connection` instead.
    pub(crate) fn send_wg_handshake_after_nomination(&self) -> bool {
        match self {
            Self::Ice(a, _) => a.controlling(),
            Self::Frostlink(_) => false,
        }
    }

    pub(crate) fn local_ufrag(&self) -> Option<&str> {
        match self {
            Self::Ice(a, _) => Some(&a.local_credentials().ufrag),
            Self::Frostlink(_) => None,
        }
    }

    pub(crate) fn set_local_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a, _) => a.set_local_credentials(creds),
            Self::Frostlink(_) => {}
        }
    }

    pub(crate) fn set_remote_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a, _) => a.set_remote_credentials(creds),
            Self::Frostlink(_) => {}
        }
    }

    pub(crate) fn add_local_candidate(
        &mut self,
        c: Candidate,
        origin: CandidateOrigin,
        now: Instant,
    ) -> Option<Candidate> {
        match self {
            Self::Ice(a, _) => a.add_local_candidate(c).cloned(),
            Self::Frostlink(agent) => {
                let candidate = crate::candidate::to_frostlink(&c)
                    .with_local_preference(origin.frostlink_local_preference());

                agent
                    .add_local_candidate(candidate, now)
                    .then(|| crate::candidate::from_frostlink(&candidate))
                    .flatten()
            }
        }
    }

    pub(crate) fn add_remote_candidate(&mut self, c: Candidate, now: Instant) {
        match self {
            Self::Ice(a, _) => a.add_remote_candidate(c),
            Self::Frostlink(agent) => {
                agent.add_remote_candidate(crate::candidate::to_frostlink(&c), now)
            }
        }
    }

    pub(crate) fn invalidate_candidate(&mut self, c: &Candidate, now: Instant) -> bool {
        match self {
            Self::Ice(a, _) => a.invalidate_candidate(c),
            Self::Frostlink(agent) => {
                let candidate = crate::candidate::to_frostlink(c);
                let removed_local = agent.remove_local_candidate(&candidate, now);
                let removed_remote = agent.remove_remote_candidate(&candidate, now);

                removed_local || removed_remote
            }
        }
    }

    pub(crate) fn local_candidates(&self) -> Box<dyn Iterator<Item = Candidate> + '_> {
        match self {
            Self::Ice(a, _) => Box::new(a.local_candidates()),
            Self::Frostlink(agent) => Box::new(
                agent
                    .local_candidates()
                    .filter_map(|c| crate::candidate::from_frostlink(&c)),
            ),
        }
    }

    pub(crate) fn remote_candidates(&self) -> Box<dyn Iterator<Item = Candidate> + '_> {
        match self {
            Self::Ice(a, _) => Box::new(a.remote_candidates()),
            Self::Frostlink(agent) => Box::new(
                agent
                    .remote_candidates()
                    .filter_map(|c| crate::candidate::from_frostlink(&c)),
            ),
        }
    }

    pub(crate) fn contains_remote_candidate(&self, c: &Candidate) -> bool {
        match self {
            Self::Ice(a, _) => a.remote_candidates().any(|x| &x == c),
            Self::Frostlink(agent) => {
                agent.contains_remote_candidate(&crate::candidate::to_frostlink(c))
            }
        }
    }

    pub(crate) fn has_remote_candidate(&self, addr: std::net::SocketAddr) -> bool {
        match self {
            Self::Ice(a, _) => a.remote_candidates().any(|c| c.addr() == addr),
            Self::Frostlink(agent) => agent.remote_candidates().any(|c| c.addr() == addr),
        }
    }

    pub(crate) fn remote_candidate_is_relayed(&self, addr: std::net::SocketAddr) -> bool {
        match self {
            Self::Ice(a, _) => a
                .remote_candidates()
                .any(|c| c.addr() == addr && c.kind() == is::CandidateKind::Relayed),
            Self::Frostlink(agent) => agent.remote_is_relayed(addr),
        }
    }

    /// Whether the peer answered a probe on `path`. Always `false` on `Self::Ice`.
    pub(crate) fn is_validated(&self, path: (std::net::SocketAddr, std::net::SocketAddr)) -> bool {
        match self {
            Self::Ice(..) => false,
            Self::Frostlink(agent) => agent.is_validated(path),
        }
    }

    /// Returns whether `path` was newly refused.
    ///
    /// `Self::Ice` only records it: its STUN messages on a refused path are kept from it.
    pub(crate) fn refuse_path(
        &mut self,
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) -> bool {
        match self {
            Self::Ice(_, refused) => refused.insert(path),
            Self::Frostlink(agent) => agent.refuse_path(path, now),
        }
    }

    /// No-op on `Self::Ice`.
    pub(crate) fn reprobe_path(
        &mut self,
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) {
        match self {
            Self::Ice(..) => {}
            Self::Frostlink(agent) => agent.reprobe_path(path, now),
        }
    }

    pub(crate) fn handle_stun_packet(&mut self, now: Instant, p: StunPacket<'_>) -> bool {
        match self {
            Self::Ice(a, _) => a.handle_packet(now, p),
            Self::Frostlink(_) => false,
        }
    }

    pub(crate) fn handle_inbound_data(&mut self, now: Instant) {
        match self {
            Self::Ice(..) => {}
            Self::Frostlink(agent) => agent.handle_inbound_data(now),
        }
    }

    pub(crate) fn handle_probe(
        &mut self,
        probe: frostlink::Probe,
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) {
        match self {
            Self::Ice(..) => {}
            Self::Frostlink(agent) => agent.handle_probe(probe, path, now),
        }
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        match self {
            Self::Ice(a, _) => a.handle_timeout(now),
            Self::Frostlink(agent) => agent.handle_timeout(now),
        }
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<Instant> {
        match self {
            Self::Ice(a, _) => a.poll_timeout(),
            Self::Frostlink(agent) => agent.poll_timeout(),
        }
    }

    pub(crate) fn poll_ice_event(&mut self) -> Option<IceAgentEvent> {
        match self {
            Self::Ice(a, _) => a.poll_event(),
            Self::Frostlink(_) => None,
        }
    }

    pub(crate) fn poll_ice_transmit(&mut self) -> Option<str0m_proto::Transmit> {
        match self {
            Self::Ice(a, _) => a.poll_transmit(),
            Self::Frostlink(_) => None,
        }
    }

    pub(crate) fn poll_frostlink_event(&mut self) -> Option<frostlink::Event> {
        match self {
            Self::Ice(..) => None,
            Self::Frostlink(agent) => agent.poll_event(),
        }
    }

    pub(crate) fn confirm_session(&mut self, now: Instant) {
        if let Self::Frostlink(agent) = self {
            agent.confirm_session(now);
        }
    }

    pub(crate) fn poll_frostlink_transmit(&mut self) -> Option<frostlink::Transmit> {
        match self {
            Self::Ice(..) => None,
            Self::Frostlink(agent) => agent.poll_transmit(),
        }
    }
}
