//! Connection-level agent dispatch over `Agent::Ice` (str0m) or
//! `Agent::Path` (iceless). Mode-irrelevant operations are no-ops on
//! the wrong variant.

use std::ops::ControlFlow;
use std::time::Instant;

use boringtun::noise::Tunn;
use is::stun::StunPacket;
use is::{Candidate, IceAgent, IceAgentEvent, IceConnectionState, IceCreds};

use crate::{IceConfig, IceRole};

#[derive(derive_more::Debug)]
pub(crate) enum Agent {
    Ice(IceAgent),
    Path(#[debug(skip)] path_agent::PathAgent),
}

impl Agent {
    pub(crate) fn ice(agent: IceAgent) -> Self {
        Self::Ice(agent)
    }

    pub(crate) fn path() -> Self {
        Self::Path(path_agent::PathAgent::new())
    }

    pub(crate) fn is_iceless(&self) -> bool {
        matches!(self, Self::Path(_))
    }

    /// Rebuild the inner `PathAgent`, dropping locals matching
    /// `should_drop_local` and preserving every remote. No-op on `Self::Ice`.
    pub(crate) fn rebuild_path(
        &mut self,
        should_drop_local: impl FnMut(&path_agent::Candidate) -> bool,
        now: Instant,
    ) {
        if let Self::Path(path) = self {
            path.rebuild(should_drop_local, now);
        }
    }

    pub(crate) fn is_negotiation_complete(&self) -> bool {
        match self {
            Self::Ice(a) => a.state() == IceConnectionState::Connected,
            Self::Path(path) => path.primary().is_some(),
        }
    }

    pub(crate) fn apply_ice_config(&mut self, config: IceConfig) {
        if let Self::Ice(a) = self {
            a.set_max_stun_retransmits(config.max_retrans);
            a.set_max_stun_rto(config.max_rto);
            a.set_initial_stun_rto(config.initial_rto);
        }
    }

    /// A mismatched `want_iceless` forces replacement so a flag flip
    /// between upserts actually takes effect.
    pub(crate) fn matches_existing_connection(
        &self,
        local_creds: &IceCreds,
        remote_creds: &IceCreds,
        ice_role: IceRole,
        want_iceless: bool,
    ) -> bool {
        if self.is_iceless() != want_iceless {
            return false;
        }
        match self {
            Self::Ice(a) => {
                a.local_credentials() == local_creds
                    && a.remote_credentials().is_some_and(|c| c == remote_creds)
                    && a.controlling() == matches!(ice_role, IceRole::Controlling)
            }
            Self::Path(_) => true,
        }
    }

    /// Iceless fans the init out from `upsert_connection` instead.
    pub(crate) fn send_wg_handshake_after_nomination(&self) -> bool {
        match self {
            Self::Ice(a) => a.controlling(),
            Self::Path(_) => false,
        }
    }

    pub(crate) fn local_ufrag(&self) -> Option<&str> {
        match self {
            Self::Ice(a) => Some(&a.local_credentials().ufrag),
            Self::Path(_) => None,
        }
    }

    pub(crate) fn set_local_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_local_credentials(creds),
            Self::Path(_) => {}
        }
    }

    pub(crate) fn set_remote_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_remote_credentials(creds),
            Self::Path(_) => {}
        }
    }

    pub(crate) fn add_local_candidate(&mut self, c: Candidate) -> Option<Candidate> {
        match self {
            Self::Ice(a) => a.add_local_candidate(c).cloned(),
            Self::Path(path) => path
                .add_local_candidate(crate::candidate::to_path_agent(&c))
                .then_some(c),
        }
    }

    pub(crate) fn add_remote_candidate(&mut self, c: Candidate, now: Instant) {
        match self {
            Self::Ice(a) => a.add_remote_candidate(c),
            Self::Path(path) => path.add_remote_candidate(crate::candidate::to_path_agent(&c), now),
        }
    }

    pub(crate) fn invalidate_candidate(&mut self, c: &Candidate, now: Instant) -> bool {
        match self {
            Self::Ice(a) => a.invalidate_candidate(c),
            Self::Path(path) => {
                let candidate = crate::candidate::to_path_agent(c);
                let removed_local = path.remove_local_candidate(&candidate, now);
                let removed_remote = path.remove_remote_candidate(&candidate, now);

                removed_local || removed_remote
            }
        }
    }

    pub(crate) fn local_candidates(&self) -> Box<dyn Iterator<Item = Candidate> + '_> {
        match self {
            Self::Ice(a) => Box::new(a.local_candidates()),
            Self::Path(path) => Box::new(
                path.local_candidates()
                    .filter_map(|c| crate::candidate::from_path_agent(&c)),
            ),
        }
    }

    pub(crate) fn remote_candidates(&self) -> Box<dyn Iterator<Item = Candidate> + '_> {
        match self {
            Self::Ice(a) => Box::new(a.remote_candidates()),
            Self::Path(path) => Box::new(
                path.remote_candidates()
                    .filter_map(|c| crate::candidate::from_path_agent(&c)),
            ),
        }
    }

    pub(crate) fn contains_remote_candidate(&self, c: &Candidate) -> bool {
        match self {
            Self::Ice(a) => a.remote_candidates().any(|x| &x == c),
            Self::Path(path) => path.contains_remote_candidate(&crate::candidate::to_path_agent(c)),
        }
    }

    pub(crate) fn remote_candidate_is_relayed(&self, addr: std::net::SocketAddr) -> bool {
        match self {
            Self::Ice(a) => a
                .remote_candidates()
                .any(|c| c.addr() == addr && c.kind() == is::CandidateKind::Relayed),
            Self::Path(path) => path.remote_is_relayed(addr),
        }
    }

    pub(crate) fn handle_stun_packet(&mut self, now: Instant, p: StunPacket<'_>) -> bool {
        match self {
            Self::Ice(a) => a.handle_packet(now, p),
            Self::Path(_) => false,
        }
    }

    pub(crate) fn handle_inbound_network<'b>(
        &mut self,
        tunnel: &mut Tunn,
        bytes: &'b [u8],
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) -> ControlFlow<(), &'b [u8]> {
        match self {
            Self::Ice(_) => ControlFlow::Continue(bytes),
            Self::Path(agent) => agent.handle_inbound_network(tunnel, bytes, path, now),
        }
    }

    pub(crate) fn handle_inbound_tun(
        &mut self,
        packet: ip_packet::IpPacket,
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) -> ControlFlow<(), ip_packet::IpPacket> {
        match self {
            Self::Ice(_) => ControlFlow::Continue(packet),
            Self::Path(agent) => agent.handle_inbound_tun(packet, path, now),
        }
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        match self {
            Self::Ice(a) => a.handle_timeout(now),
            Self::Path(path) => path.handle_timeout(now),
        }
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<Instant> {
        match self {
            Self::Ice(a) => a.poll_timeout(),
            Self::Path(path) => path.poll_timeout(),
        }
    }

    pub(crate) fn poll_ice_event(&mut self) -> Option<IceAgentEvent> {
        match self {
            Self::Ice(a) => a.poll_event(),
            Self::Path(_) => None,
        }
    }

    pub(crate) fn poll_ice_transmit(&mut self) -> Option<str0m_proto::Transmit> {
        match self {
            Self::Ice(a) => a.poll_transmit(),
            Self::Path(_) => None,
        }
    }

    pub(crate) fn poll_path_event(&mut self) -> Option<path_agent::Event> {
        match self {
            Self::Ice(_) => None,
            Self::Path(path) => path.poll_event(),
        }
    }

    pub(crate) fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        if let Self::Path(path) = self {
            path.handle_outbound(bytes, now);
        }
    }

    pub(crate) fn initiate_handshake(
        &mut self,
        tunnel: &mut Tunn,
        force_resend: bool,
        now: Instant,
    ) {
        if let Self::Path(path) = self {
            path.initiate_handshake(tunnel, force_resend, now);
        }
    }

    pub(crate) fn poll_path_transmit(&mut self) -> Option<path_agent::Transmit> {
        match self {
            Self::Ice(_) => None,
            Self::Path(path) => path.poll_transmit(),
        }
    }
}
