//! Connection-level agent dispatch over `Agent::Ice` (str0m) or
//! `Agent::Frostlink`. Mode-irrelevant operations are no-ops on
//! the wrong variant.

use std::time::Instant;

use is::stun::StunPacket;
use is::{Candidate, IceAgent, IceAgentEvent, IceConnectionState, IceCreds};

use crate::{IceConfig, IceRole};

#[derive(derive_more::Debug)]
pub(crate) enum Agent {
    Ice(IceAgent),
    Frostlink(#[debug(skip)] frostlink::Agent),
}

impl Agent {
    pub(crate) fn ice(agent: IceAgent) -> Self {
        Self::Ice(agent)
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
            Self::Ice(a) => a.state() == IceConnectionState::Connected,
            Self::Frostlink(agent) => agent.primary().is_some(),
        }
    }

    pub(crate) fn apply_ice_config(&mut self, config: IceConfig) {
        if let Self::Ice(a) = self {
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
            Self::Ice(a) => {
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
            Self::Ice(a) => a.controlling(),
            Self::Frostlink(_) => false,
        }
    }

    pub(crate) fn local_ufrag(&self) -> Option<&str> {
        match self {
            Self::Ice(a) => Some(&a.local_credentials().ufrag),
            Self::Frostlink(_) => None,
        }
    }

    pub(crate) fn set_local_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_local_credentials(creds),
            Self::Frostlink(_) => {}
        }
    }

    pub(crate) fn set_remote_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_remote_credentials(creds),
            Self::Frostlink(_) => {}
        }
    }

    pub(crate) fn add_local_candidate(&mut self, c: Candidate, now: Instant) -> Option<Candidate> {
        match self {
            Self::Ice(a) => a.add_local_candidate(c).cloned(),
            Self::Frostlink(agent) => agent
                .add_local_candidate(crate::candidate::to_frostlink(&c), now)
                .then_some(c),
        }
    }

    pub(crate) fn add_remote_candidate(&mut self, c: Candidate, now: Instant) {
        match self {
            Self::Ice(a) => a.add_remote_candidate(c),
            Self::Frostlink(agent) => {
                agent.add_remote_candidate(crate::candidate::to_frostlink(&c), now)
            }
        }
    }

    pub(crate) fn invalidate_candidate(&mut self, c: &Candidate, now: Instant) -> bool {
        match self {
            Self::Ice(a) => a.invalidate_candidate(c),
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
            Self::Ice(a) => Box::new(a.local_candidates()),
            Self::Frostlink(agent) => Box::new(
                agent
                    .local_candidates()
                    .filter_map(|c| crate::candidate::from_frostlink(&c)),
            ),
        }
    }

    pub(crate) fn remote_candidates(&self) -> Box<dyn Iterator<Item = Candidate> + '_> {
        match self {
            Self::Ice(a) => Box::new(a.remote_candidates()),
            Self::Frostlink(agent) => Box::new(
                agent
                    .remote_candidates()
                    .filter_map(|c| crate::candidate::from_frostlink(&c)),
            ),
        }
    }

    pub(crate) fn contains_remote_candidate(&self, c: &Candidate) -> bool {
        match self {
            Self::Ice(a) => a.remote_candidates().any(|x| &x == c),
            Self::Frostlink(agent) => {
                agent.contains_remote_candidate(&crate::candidate::to_frostlink(c))
            }
        }
    }

    pub(crate) fn remote_candidate_is_relayed(&self, addr: std::net::SocketAddr) -> bool {
        match self {
            Self::Ice(a) => a
                .remote_candidates()
                .any(|c| c.addr() == addr && c.kind() == is::CandidateKind::Relayed),
            Self::Frostlink(agent) => agent.remote_is_relayed(addr),
        }
    }

    pub(crate) fn handle_stun_packet(&mut self, now: Instant, p: StunPacket<'_>) -> bool {
        match self {
            Self::Ice(a) => a.handle_packet(now, p),
            Self::Frostlink(_) => false,
        }
    }

    pub(crate) fn handle_probe(
        &mut self,
        probe: frostlink::Probe,
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) {
        match self {
            Self::Ice(_) => {}
            Self::Frostlink(agent) => agent.handle_probe(probe, path, now),
        }
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        match self {
            Self::Ice(a) => a.handle_timeout(now),
            Self::Frostlink(agent) => agent.handle_timeout(now),
        }
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<Instant> {
        match self {
            Self::Ice(a) => a.poll_timeout(),
            Self::Frostlink(agent) => agent.poll_timeout(),
        }
    }

    pub(crate) fn poll_ice_event(&mut self) -> Option<IceAgentEvent> {
        match self {
            Self::Ice(a) => a.poll_event(),
            Self::Frostlink(_) => None,
        }
    }

    pub(crate) fn poll_ice_transmit(&mut self) -> Option<str0m_proto::Transmit> {
        match self {
            Self::Ice(a) => a.poll_transmit(),
            Self::Frostlink(_) => None,
        }
    }

    pub(crate) fn poll_frostlink_event(&mut self) -> Option<frostlink::Event> {
        match self {
            Self::Ice(_) => None,
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
            Self::Ice(_) => None,
            Self::Frostlink(agent) => agent.poll_transmit(),
        }
    }
}
