//! Connection-level agent dispatch over `Agent::Ice` (str0m) or
//! `Agent::Path` (iceless). Mode-irrelevant operations are no-ops on
//! the wrong variant.

use std::collections::VecDeque;
use std::ops::ControlFlow;
use std::time::Instant;

use boringtun::noise::Tunn;
use is::stun::StunPacket;
use is::{Candidate, CandidateKind, IceAgent, IceAgentEvent, IceConnectionState, IceCreds};
use smallvec::SmallVec;

use crate::{IceConfig, IceRole};

/// Per-kind FIFO cap on remote candidates, bounding `pairs` growth
/// across portal-driven relay rotations.
const MAX_REMOTE_PER_KIND: usize = 6;

#[derive(derive_more::Debug)]
pub(crate) enum Agent {
    Ice(IceAgent),
    Path {
        local_candidates: Vec<Candidate>,
        remote_host: VecDeque<Candidate>,
        remote_srflx: VecDeque<Candidate>,
        remote_relayed: VecDeque<Candidate>,
        #[debug(skip)]
        path: path_agent::PathAgent,
    },
}

impl Agent {
    pub(crate) fn ice(agent: IceAgent) -> Self {
        Self::Ice(agent)
    }

    pub(crate) fn path() -> Self {
        Self::Path {
            local_candidates: Vec::new(),
            remote_host: VecDeque::new(),
            remote_srflx: VecDeque::new(),
            remote_relayed: VecDeque::new(),
            path: path_agent::PathAgent::new(),
        }
    }

    pub(crate) fn is_iceless(&self) -> bool {
        matches!(self, Self::Path { .. })
    }

    /// Rebuild the inner `PathAgent`, dropping locals matching
    /// `should_drop_local` and preserving every remote. No-op on
    /// `Self::Ice`.
    pub(crate) fn rebuild_path(&mut self, mut should_drop_local: impl FnMut(&Candidate) -> bool) {
        let Self::Path {
            local_candidates,
            remote_host,
            remote_srflx,
            remote_relayed,
            path,
        } = self
        else {
            return;
        };

        let _dropped: SmallVec<[Candidate; 4]> = local_candidates
            .extract_if(.., |c| should_drop_local(c))
            .collect();

        *path = path_agent::PathAgent::new();
        for c in local_candidates.iter() {
            path.add_local_candidate(crate::candidate::to_path_agent(c));
        }
        for c in remote_host
            .iter()
            .chain(remote_srflx.iter())
            .chain(remote_relayed.iter())
        {
            path.add_remote_candidate(crate::candidate::to_path_agent(c));
        }
    }

    pub(crate) fn is_negotiation_complete(&self) -> bool {
        match self {
            Self::Ice(a) => a.state() == IceConnectionState::Connected,
            Self::Path { path, .. } => path.primary().is_some(),
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
            Self::Path { .. } => true,
        }
    }

    /// Iceless fans the init out from `upsert_connection` instead.
    pub(crate) fn send_wg_handshake_after_nomination(&self) -> bool {
        match self {
            Self::Ice(a) => a.controlling(),
            Self::Path { .. } => false,
        }
    }

    pub(crate) fn local_ufrag(&self) -> Option<&str> {
        match self {
            Self::Ice(a) => Some(&a.local_credentials().ufrag),
            Self::Path { .. } => None,
        }
    }

    pub(crate) fn set_local_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_local_credentials(creds),
            Self::Path { .. } => {}
        }
    }

    pub(crate) fn set_remote_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_remote_credentials(creds),
            Self::Path { .. } => {}
        }
    }

    pub(crate) fn add_local_candidate(&mut self, c: Candidate) -> Option<&Candidate> {
        match self {
            Self::Ice(a) => a.add_local_candidate(c),
            Self::Path {
                local_candidates,
                path,
                ..
            } => {
                if local_candidates.contains(&c) {
                    return None;
                }
                path.add_local_candidate(crate::candidate::to_path_agent(&c));
                local_candidates.push(c);
                local_candidates.last()
            }
        }
    }

    pub(crate) fn add_remote_candidate(&mut self, c: Candidate, now: Instant) {
        match self {
            Self::Ice(a) => a.add_remote_candidate(c),
            Self::Path {
                remote_host,
                remote_srflx,
                remote_relayed,
                path,
                ..
            } => {
                let bucket =
                    bucket_for_kind_mut(c.kind(), remote_host, remote_srflx, remote_relayed);
                if bucket.contains(&c) {
                    return;
                }
                if bucket.len() >= MAX_REMOTE_PER_KIND {
                    let evicted = bucket
                        .pop_front()
                        .expect("len >= MAX_REMOTE_PER_KIND implies non-empty");
                    tracing::debug!(
                        evicted = ?evicted,
                        kind = ?c.kind(),
                        "Evicting oldest remote candidate to honour per-kind cap",
                    );
                    path.remove_remote_candidate(&crate::candidate::to_path_agent(&evicted), now);
                }
                path.add_remote_candidate(crate::candidate::to_path_agent(&c));
                bucket.push_back(c);
            }
        }
    }

    pub(crate) fn invalidate_candidate(&mut self, c: &Candidate, now: Instant) -> bool {
        match self {
            Self::Ice(a) => a.invalidate_candidate(c),
            Self::Path {
                local_candidates,
                remote_host,
                remote_srflx,
                remote_relayed,
                path,
            } => {
                let pa_c = crate::candidate::to_path_agent(c);
                let removed_local = local_candidates
                    .iter()
                    .position(|x| x == c)
                    .map(|i| local_candidates.remove(i))
                    .is_some();
                let removed_remote = remove_from_bucket(remote_host, c)
                    || remove_from_bucket(remote_srflx, c)
                    || remove_from_bucket(remote_relayed, c);
                if removed_local {
                    path.remove_local_candidate(&pa_c, now);
                }
                if removed_remote {
                    path.remove_remote_candidate(&pa_c, now);
                }
                removed_local || removed_remote
            }
        }
    }

    pub(crate) fn local_candidates(&self) -> Box<dyn Iterator<Item = Candidate> + '_> {
        match self {
            Self::Ice(a) => Box::new(a.local_candidates()),
            Self::Path {
                local_candidates, ..
            } => Box::new(local_candidates.iter().cloned()),
        }
    }

    pub(crate) fn remote_candidates(&self) -> Box<dyn Iterator<Item = Candidate> + '_> {
        match self {
            Self::Ice(a) => Box::new(a.remote_candidates()),
            Self::Path {
                remote_host,
                remote_srflx,
                remote_relayed,
                ..
            } => Box::new(
                remote_host
                    .iter()
                    .chain(remote_srflx.iter())
                    .chain(remote_relayed.iter())
                    .cloned(),
            ),
        }
    }

    pub(crate) fn contains_remote_candidate(&self, c: &Candidate) -> bool {
        match self {
            Self::Ice(a) => a.remote_candidates().any(|x| &x == c),
            Self::Path {
                remote_host,
                remote_srflx,
                remote_relayed,
                ..
            } => remote_host
                .iter()
                .chain(remote_srflx.iter())
                .chain(remote_relayed.iter())
                .any(|x| x == c),
        }
    }

    pub(crate) fn remote_candidate_is_relayed(&self, addr: std::net::SocketAddr) -> bool {
        match self {
            Self::Ice(a) => a
                .remote_candidates()
                .any(|c| c.addr() == addr && c.kind() == is::CandidateKind::Relayed),
            Self::Path { path, .. } => path.remote_is_relayed(addr),
        }
    }

    pub(crate) fn handle_stun_packet(&mut self, now: Instant, p: StunPacket<'_>) -> bool {
        match self {
            Self::Ice(a) => a.handle_packet(now, p),
            Self::Path { .. } => false,
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
            Self::Path { path: agent, .. } => {
                agent.handle_inbound_network(tunnel, bytes, path, now)
            }
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
            Self::Path { path: agent, .. } => agent.handle_inbound_tun(packet, path, now),
        }
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        match self {
            Self::Ice(a) => a.handle_timeout(now),
            Self::Path { path, .. } => path.handle_timeout(now),
        }
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<Instant> {
        match self {
            Self::Ice(a) => a.poll_timeout(),
            Self::Path { path, .. } => path.poll_timeout(),
        }
    }

    pub(crate) fn poll_ice_event(&mut self) -> Option<IceAgentEvent> {
        match self {
            Self::Ice(a) => a.poll_event(),
            Self::Path { .. } => None,
        }
    }

    pub(crate) fn poll_ice_transmit(&mut self) -> Option<str0m_proto::Transmit> {
        match self {
            Self::Ice(a) => a.poll_transmit(),
            Self::Path { .. } => None,
        }
    }

    pub(crate) fn poll_path_event(&mut self) -> Option<path_agent::Event> {
        match self {
            Self::Ice(_) => None,
            Self::Path { path, .. } => path.poll_event(),
        }
    }

    pub(crate) fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        if let Self::Path { path, .. } = self {
            path.handle_outbound(bytes, now);
        }
    }

    pub(crate) fn initiate_handshake(
        &mut self,
        tunnel: &mut Tunn,
        force_resend: bool,
        now: Instant,
    ) {
        if let Self::Path { path, .. } = self {
            path.initiate_handshake(tunnel, force_resend, now);
        }
    }

    pub(crate) fn poll_path_transmit(&mut self) -> Option<path_agent::Transmit> {
        match self {
            Self::Ice(_) => None,
            Self::Path { path, .. } => path.poll_transmit(),
        }
    }
}

/// `PeerReflexive` collapses into the server-reflexive bucket.
fn bucket_for_kind_mut<'a>(
    kind: CandidateKind,
    host: &'a mut VecDeque<Candidate>,
    srflx: &'a mut VecDeque<Candidate>,
    relayed: &'a mut VecDeque<Candidate>,
) -> &'a mut VecDeque<Candidate> {
    match kind {
        CandidateKind::Host => host,
        CandidateKind::ServerReflexive | CandidateKind::PeerReflexive => srflx,
        CandidateKind::Relayed => relayed,
    }
}

fn remove_from_bucket(bucket: &mut VecDeque<Candidate>, c: &Candidate) -> bool {
    bucket
        .iter()
        .position(|x| x == c)
        .map(|i| bucket.remove(i))
        .is_some()
}
