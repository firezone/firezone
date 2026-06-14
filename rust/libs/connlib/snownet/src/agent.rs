//! Connection-level agent dispatch.
//!
//! `Agent::Ice` wraps the legacy str0m `IceAgent`. `Agent::Path` wraps a
//! `path_agent::PathAgent` plus the candidate lists snownet still needs
//! to query (no credentials, no role).
//!
//! Call sites stay agent-agnostic by going through named decision
//! methods (`send_wg_handshake_after_nomination`,
//! `wait_for_nomination_before_wg_handshake`, etc.) rather than poking
//! at variant-specific state. ICE-only operations on `Path` are no-ops:
//! `handle_stun_packet` returns `false`, `set_*_credentials` drop the
//! creds, `poll_ice_event` / `poll_ice_transmit` return `None`. Path-
//! agent-only operations on `Ice` mirror that.

use std::collections::VecDeque;
use std::ops::ControlFlow;
use std::time::Instant;

use boringtun::noise::Tunn;
use is::stun::StunPacket;
use is::{Candidate, CandidateKind, IceAgent, IceAgentEvent, IceConnectionState, IceCreds};
use smallvec::SmallVec;

use crate::{IceConfig, IceRole};

/// FIFO cap on remote candidates per kind. Each portal-driven relay
/// rotation can add a fresh remote relay candidate without us evicting
/// the old one; without a cap, `pairs` (= `locals × remotes`) would grow
/// unbounded over the lifetime of a long-lived connection. Splitting by
/// kind keeps a runaway burst on one axis (e.g. many relay candidates
/// from a flapping portal) from evicting still-useful host candidates.
const MAX_REMOTE_PER_KIND: usize = 6;

#[derive(derive_more::Debug)]
pub(crate) enum Agent {
    Ice(IceAgent),
    Path {
        local_candidates: Vec<Candidate>,
        /// Remote host candidates. FIFO-bounded at
        /// [`MAX_REMOTE_PER_KIND`].
        remote_host: VecDeque<Candidate>,
        /// Remote server-reflexive (and peer-reflexive) candidates.
        /// FIFO-bounded at [`MAX_REMOTE_PER_KIND`].
        remote_srflx: VecDeque<Candidate>,
        /// Remote relayed candidates. FIFO-bounded at
        /// [`MAX_REMOTE_PER_KIND`].
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

    /// Rebuild the inner `PathAgent` and re-seed it from the surviving
    /// candidates. `should_drop_local` decides which local candidates
    /// are no longer valid:
    ///
    /// - Roam: pass `|_| true` — local IPs changed, drop everything.
    /// - Relay replacement: pass a predicate that matches the dead
    ///   allocation's candidates — host / srflx / other-relay
    ///   candidates stay.
    ///
    /// Remote candidates are always preserved: they're attached to the
    /// peer's network, which hasn't changed under us.
    ///
    /// No-op on `Self::Ice` — ICE-based connections rely on the
    /// node-level key rotation + close-and-reopen path (roam) or
    /// per-candidate `InvalidateIceCandidate` signalling (relay
    /// replacement).
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

        // `extract_if` is lazy — collecting into a SmallVec consumes
        // it, performing the removal. Inline-capacity 4 covers host +
        // srflx + up-to-two relays without spilling.
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

    /// Whether negotiation has progressed far enough that the snownet
    /// idle-state machine can run. ICE: connected. Iceless: a primary path
    /// has been selected.
    pub(crate) fn is_negotiation_complete(&self) -> bool {
        match self {
            Self::Ice(a) => a.state() == IceConnectionState::Connected,
            Self::Path { path, .. } => path.primary().is_some(),
        }
    }

    /// Apply ICE-specific STUN-retransmit configuration. No-op for iceless.
    pub(crate) fn apply_ice_config(&mut self, config: IceConfig) {
        if let Self::Ice(a) = self {
            a.set_max_stun_retransmits(config.max_retrans);
            a.set_max_stun_rto(config.max_rto);
            a.set_initial_stun_rto(config.initial_rto);
        }
    }

    /// Whether `upsert_connection` may reuse this existing agent.
    /// Iceless mode silently ignores `local_creds` / `remote_creds` /
    /// `ice_role` — the reuse-relevant dimensions (pubkey, PSK) live on
    /// the caller. If `upsert_connection` ever needs creds/role honoured
    /// here, the `Path` arm has to participate.
    ///
    /// `want_iceless` reflects the agent mode the caller would build
    /// today. A mismatch (e.g. negotiated capability or local feature
    /// flag flipped between upserts) forces replacement so the new mode
    /// actually takes effect.
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

    /// Whether to send a WG `HandshakeInit` after nominating a peer
    /// socket. ICE controlling: yes. ICE controlled: no. Iceless: no
    /// (fans out the init in `upsert_connection` directly, no nomination
    /// step).
    pub(crate) fn send_wg_handshake_after_nomination(&self) -> bool {
        match self {
            Self::Ice(a) => a.controlling(),
            Self::Path { .. } => false,
        }
    }

    /// Whether to hold WG traffic until nomination lands. ICE controlled:
    /// yes. ICE controlling: no. Iceless: no.
    pub(crate) fn wait_for_nomination_before_wg_handshake(&self) -> bool {
        match self {
            Self::Ice(a) => !a.controlling(),
            Self::Path { .. } => false,
        }
    }

    /// Local ICE ufrag, used by the recent-disconnect cache. `None` for
    /// iceless (no creds means no cache key).
    pub(crate) fn local_ufrag(&self) -> Option<&str> {
        match self {
            Self::Ice(a) => Some(&a.local_credentials().ufrag),
            Self::Path { .. } => None,
        }
    }

    pub(crate) fn set_local_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_local_credentials(creds),
            Self::Path { .. } => {} // Iceless has no ICE creds.
        }
    }

    pub(crate) fn set_remote_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_remote_credentials(creds),
            Self::Path { .. } => {} // Iceless has no ICE creds.
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
                // FIFO eviction: drop the oldest of this kind to make
                // room. Mirrors into `path` so pair / primary state
                // stays in sync.
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

    /// `true` iff `addr` is a remote relay candidate. Used to classify
    /// the resulting `PeerSocket` for a freshly-nominated send pair.
    pub(crate) fn remote_candidate_is_relayed(&self, addr: std::net::SocketAddr) -> bool {
        match self {
            Self::Ice(a) => a
                .remote_candidates()
                .any(|c| c.addr() == addr && c.kind() == is::CandidateKind::Relayed),
            Self::Path { path, .. } => path.remote_is_relayed(addr),
        }
    }

    /// Inbound STUN. `false` on the `Path` arm — iceless doesn't speak
    /// STUN, so the caller treats the packet as non-STUN.
    pub(crate) fn handle_stun_packet(&mut self, now: Instant, p: StunPacket<'_>) -> bool {
        match self {
            Self::Ice(a) => a.handle_packet(now, p),
            Self::Path { .. } => false,
        }
    }

    /// Inbound WG bytes. See [`path_agent::PathAgent::handle_inbound_network`].
    /// Always `Continue(())` on the `Ice` arm.
    pub(crate) fn handle_inbound_network(
        &mut self,
        bytes: &[u8],
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) -> ControlFlow<()> {
        match self {
            Self::Ice(_) => ControlFlow::Continue(()),
            Self::Path { path: agent, .. } => agent.handle_inbound_network(bytes, path, now),
        }
    }

    /// Decrypted inner-IP packet. See
    /// [`path_agent::PathAgent::handle_inbound_tun`]. The `Ice` arm
    /// never absorbs inner traffic, so it hands the packet straight back.
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

    /// Outbound WG bytes from boringtun. No-op on the `Ice` arm — ICE
    /// uses the existing `peer_socket`-based single-send path.
    pub(crate) fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        if let Self::Path { path, .. } = self {
            path.handle_outbound(bytes, now);
        }
    }

    /// Iceless-mode helper: ask `tunnel` for a `HandshakeInit` and
    /// route it through the inner `PathAgent`. No-op on `Self::Ice`
    /// — ICE-based connections initiate after nomination via
    /// `Connection::initiate_wg_session`.
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

/// Map an `is::CandidateKind` to the matching bucket (mutable).
/// `PeerReflexive` collapses into the server-reflexive bucket — both
/// shapes are server-reflexive from the path-agent's perspective.
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

/// Remove `c` from `bucket` if present. Returns whether it was found.
fn remove_from_bucket(bucket: &mut VecDeque<Candidate>, c: &Candidate) -> bool {
    bucket
        .iter()
        .position(|x| x == c)
        .map(|i| bucket.remove(i))
        .is_some()
}
