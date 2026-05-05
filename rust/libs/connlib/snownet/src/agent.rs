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

use std::ops::ControlFlow;
use std::time::Instant;

use boringtun::noise::Tunn;
use is::stun::StunPacket;
use is::{Candidate, IceAgent, IceAgentEvent, IceConnectionState, IceCreds};

use crate::{IceConfig, IceRole};

#[derive(derive_more::Debug)]
pub(crate) enum Agent {
    Ice(IceAgent),
    Path {
        local_candidates: Vec<Candidate>,
        remote_candidates: Vec<Candidate>,
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
            remote_candidates: Vec::new(),
            path: path_agent::PathAgent::new(),
        }
    }

    pub(crate) fn is_iceless(&self) -> bool {
        matches!(self, Self::Path { .. })
    }

    /// Reset the iceless `PathAgent` for a network change (roam).
    ///
    /// Replaces `path` with a fresh `PathAgent::new()` (so any new
    /// internal field added later is reset by construction), drops
    /// the now-stale local candidates, and re-seeds the remote
    /// candidates we already knew — those don't change with our
    /// network. New local candidates flow back in via the normal
    /// `add_local_candidate` path as fresh allocations form.
    ///
    /// No-op on `Self::Ice` — ICE-based connections rely on the
    /// node-level key rotation + close-and-reopen path to detect
    /// roaming.
    pub(crate) fn reset_for_roam(&mut self) {
        let Self::Path {
            local_candidates,
            remote_candidates,
            path,
        } = self
        else {
            return;
        };

        *path = path_agent::PathAgent::new();
        local_candidates.clear();
        for c in remote_candidates.iter() {
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
    pub(crate) fn matches_existing_connection(
        &self,
        local_creds: &IceCreds,
        remote_creds: &IceCreds,
        ice_role: IceRole,
    ) -> bool {
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

    pub(crate) fn add_remote_candidate(&mut self, c: Candidate) {
        match self {
            Self::Ice(a) => a.add_remote_candidate(c),
            Self::Path {
                remote_candidates,
                path,
                ..
            } => {
                if remote_candidates.contains(&c) {
                    return;
                }
                path.add_remote_candidate(crate::candidate::to_path_agent(&c));
                remote_candidates.push(c);
            }
        }
    }

    pub(crate) fn invalidate_candidate(&mut self, c: &Candidate) -> bool {
        match self {
            Self::Ice(a) => a.invalidate_candidate(c),
            Self::Path {
                local_candidates,
                remote_candidates,
                path,
            } => {
                let pa_c = crate::candidate::to_path_agent(c);
                let removed_local = local_candidates
                    .iter()
                    .position(|x| x == c)
                    .map(|i| local_candidates.remove(i))
                    .is_some();
                let removed_remote = remote_candidates
                    .iter()
                    .position(|x| x == c)
                    .map(|i| remote_candidates.remove(i))
                    .is_some();
                if removed_local {
                    path.remove_local_candidate(&pa_c);
                }
                if removed_remote {
                    path.remove_remote_candidate(&pa_c);
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
                remote_candidates, ..
            } => Box::new(remote_candidates.iter().cloned()),
        }
    }

    pub(crate) fn contains_remote_candidate(&self, c: &Candidate) -> bool {
        match self {
            Self::Ice(a) => a.remote_candidates().any(|x| &x == c),
            Self::Path {
                remote_candidates, ..
            } => remote_candidates.iter().any(|x| x == c),
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

    /// Inbound WG bytes. See [`path_agent::PathAgent::handle_inbound`].
    /// Always `Continue(())` on the `Ice` arm.
    pub(crate) fn handle_inbound(
        &mut self,
        bytes: &[u8],
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) -> ControlFlow<()> {
        match self {
            Self::Ice(_) => ControlFlow::Continue(()),
            Self::Path { path: agent, .. } => agent.handle_inbound(bytes, path, now),
        }
    }

    /// Decrypted inner-IP packet. See
    /// [`path_agent::PathAgent::handle_inbound_decrypted`]. Always
    /// `Continue(())` on the `Ice` arm.
    pub(crate) fn handle_inbound_decrypted(
        &mut self,
        packet: &ip_packet::IpPacket,
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) -> ControlFlow<()> {
        match self {
            Self::Ice(_) => ControlFlow::Continue(()),
            Self::Path { path: agent, .. } => agent.handle_inbound_decrypted(packet, path, now),
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
